// Checks assemblies written by hxc's .NET generator.
//   verify <dll>          ILVerify over method bodies and type definitions
//   dump <dll> <items>    prints the metadata named by a comma-separated item list
//   stress-fieldlookup <dll>  calls the assembly's haxe.lang.FieldLookup from many threads at once
//   stress-arrayforward <dll> makes the first cast of one unserialized array from many threads at once
using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.Metadata.Ecma335;
using System.Reflection.PortableExecutable;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using ILVerify;

static class Program {
	static int Main(string[] args) {
		if (args.Length == 2 && args[0] == "verify") return Verify(Path.GetFullPath(args[1]));
		if (args.Length == 3 && args[0] == "dump") return Dump(Path.GetFullPath(args[1]), args[2]);
		if (args.Length == 2 && args[0] == "stress-fieldlookup") return StressFieldLookup(Path.GetFullPath(args[1]));
		if (args.Length == 2 && args[0] == "stress-arrayforward") return StressArrayForward(Path.GetFullPath(args[1]));
		Console.Error.WriteLine("usage: HxcCheck verify <dll> | dump <dll> <items> | stress-fieldlookup <dll> | stress-arrayforward <dll>");
		return 2;
	}

	// hxcs's FieldLookup.doHash: over the UTF-16 code units, kept positive.
	static int FieldHash(string s) {
		var acc = 0;
		foreach (var c in s) acc = unchecked((223 * (acc >> 1) + c) << 1);
		return (int)((uint)acc >> 1);
	}

	// From 16 threads at once, each calls FieldLookup.hash on 2,000 names no thread used before, and
	// lookupHash on each result right away and again at the end: every name must hash as hxcs hashes it
	// and map back exactly. A name whose hash another name already owns hashes to ~hash, as in hxcs, and
	// that other name must be the one lookupHash gives. Any exception fails too (server app issue 6551).
	static int StressFieldLookup(string path) {
		const int threads = 16, perThread = 2000;
		var type = Assembly.LoadFrom(path).GetType("haxe.lang.FieldLookup", true)!;
		var hash = type.GetMethod("hash", [typeof(string)])!.CreateDelegate<Func<string, int>>();
		var lookupHash = type.GetMethod("lookupHash", [typeof(int)])!.CreateDelegate<Func<int, string>>();
		// Names that collide with none of the others, so a conflict can only be with a name the table
		// started with.
		var names = new string[threads][];
		var taken = new HashSet<int>();
		for (var t = 0; t < threads; t++) {
			names[t] = new string[perThread];
			var n = 0;
			for (var i = 0; n < perThread; i++) {
				var name = "stress_" + t + "_" + i;
				if (taken.Add(FieldHash(name))) names[t][n++] = name;
			}
		}
		var problems = new System.Collections.Concurrent.ConcurrentQueue<string>();
		void Check(string name, int got) {
			var want = FieldHash(name);
			if (got == want) {
				var back = lookupHash(got);
				if (back != name) problems.Enqueue("lookupHash(" + got + ") of " + name + " gave " + (back ?? "null"));
			} else if (got == ~want) {
				var owner = lookupHash(want);
				if (owner == name) problems.Enqueue(name + " hashed to ~" + want + " but owns it");
			} else {
				problems.Enqueue(name + " hashed to " + got + ", not " + want);
			}
		}
		var start = new Barrier(threads);
		var workers = new Thread[threads];
		for (var t = 0; t < threads; t++) {
			var mine = names[t];
			workers[t] = new Thread(() => {
				var got = new int[perThread];
				start.SignalAndWait();
				try {
					for (var i = 0; i < perThread; i++) {
						got[i] = hash(mine[i]);
						Check(mine[i], got[i]);
					}
					for (var i = 0; i < perThread; i++) Check(mine[i], got[i]);
				} catch (Exception e) {
					problems.Enqueue(e.GetType().Name + ": " + e.Message);
				}
			});
			workers[t].Start();
		}
		foreach (var w in workers) w.Join();
		foreach (var p in problems.Take(20)) Console.WriteLine(p);
		Console.WriteLine("stress-fieldlookup: " + threads * perThread + " names from " + threads + " threads, " + problems.Count + " problems");
		return problems.IsEmpty ? 0 : 1;
	}

	// Haxe issue 8314's forward under a race, in three shapes. Each round calls one of the assembly's
	// makers for a fresh Array`1<object> from haxe.Unserializer and starts 8 threads behind a barrier. Each
	// casts that one array with the shape's P.toInts(a:Dynamic):Array<Int> or P.toStrings and pushes onto
	// what it got, the pushes under a lock since an Array is not thread-safe. Every thread must get the same
	// typed array, holding the original's elements and then each thread's pushes, and the original's length
	// must follow it. Any exception fails too. P.make's [1,2,3] runs 200 rounds of one push a thread;
	// P.makeFull's [1,2,3,4], which fills its capacity, and P.makeStrings's ["a",null,"b"], whose null
	// converts losslessly, run 1000 rounds of 3 pushes a thread, so a push can race a late cast's scan.
	static int StressArrayForward(string path) {
		var p = Assembly.LoadFrom(path).GetType("P", true)!;
		var failed = false;
		failed |= StressShape(p, "make", "toInts", typeof(int), [1, 2, 3], me => me, 200, 1);
		failed |= StressShape(p, "makeFull", "toInts", typeof(int), [1, 2, 3, 4], me => me, 1000, 3);
		failed |= StressShape(p, "makeStrings", "toStrings", typeof(string), ["a", null, "b"], me => "t" + me, 1000, 3);
		return failed ? 1 : 0;
	}

	// One shape of stress-arrayforward; true when it found a problem.
	static bool StressShape(Type p, string maker, string caster, Type element, object?[] initial, Func<int, object> pushed, int rounds, int pushes) {
		const int threads = 8;
		var flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;
		var make = p.GetMethod(maker, flags)!.CreateDelegate<Func<object>>();
		var cast = p.GetMethod(caster, flags)!.CreateDelegate<Func<object, object>>();
		var problems = new List<string>();
		var want = initial.Length + threads * pushes;
		var watch = System.Diagnostics.Stopwatch.StartNew();
		for (var round = 0; round < rounds; round++) {
			var a = make();
			var got = new object?[threads];
			var errors = new System.Collections.Concurrent.ConcurrentQueue<string>();
			var gate = new object();
			var start = new Barrier(threads);
			var workers = new Thread[threads];
			for (var t = 0; t < threads; t++) {
				var me = t;
				workers[t] = new Thread(() => {
					start.SignalAndWait();
					try {
						var r = cast(a);
						got[me] = r;
						var push = r.GetType().GetMethod("push")!;
						lock (gate) for (var i = 0; i < pushes; i++) push.Invoke(r, [pushed(me)]);
					} catch (Exception e) {
						var x = e is TargetInvocationException && e.InnerException != null ? e.InnerException : e;
						errors.Enqueue(x.GetType().Name + ": " + x.Message);
					}
				});
				workers[t].Start();
			}
			foreach (var w in workers) w.Join();
			var where = maker + " round " + round + ": ";
			foreach (var e in errors) problems.Add(where + e);
			var first = got[0];
			if (first == null || first.GetType() != a.GetType().GetGenericTypeDefinition().MakeGenericType(element)) {
				problems.Add(where + "thread 0 got " + (first == null ? "null" : first.GetType().ToString()));
				continue;
			}
			for (var t = 1; t < threads; t++)
				if (!ReferenceEquals(got[t], first)) problems.Add(where + "thread " + t + " got another array");
			int Length(object o) => (int)o.GetType().GetField("length")!.GetValue(o)!;
			var length = Length(first);
			if (length != want) problems.Add(where + "length " + length + ", not " + want);
			if (Length(a) != length) problems.Add(where + "the original's length is " + Length(a) + ", the target's " + length);
			var store = (System.Array)first.GetType().GetField("__a")!.GetValue(first)!;
			var values = Enumerable.Range(0, Math.Min(length, store.Length)).Select(i => store.GetValue(i)).ToArray();
			var rest = values.Skip(initial.Length).Select(v => Convert.ToString(v)).OrderBy(v => v, StringComparer.Ordinal);
			var expected = Enumerable.Range(0, threads).SelectMany(t => Enumerable.Repeat(Convert.ToString(pushed(t)), pushes)).OrderBy(v => v, StringComparer.Ordinal);
			if (!values.Take(initial.Length).SequenceEqual(initial) || !rest.SequenceEqual(expected))
				problems.Add(where + "elements " + string.Join(",", values));
		}
		foreach (var problem in problems.Take(20)) Console.WriteLine(problem);
		Console.WriteLine("stress-arrayforward " + maker + ": " + rounds + " rounds of " + threads + " threads, " + pushes + " pushes each, in "
			+ watch.ElapsedMilliseconds + " ms, " + problems.Count + " problems");
		return problems.Count != 0;
	}

	static int Verify(string path) {
		var resolver = new Resolver(path);
		var verifier = new Verifier(resolver, new VerifierOptions { SanityChecks = true });
		verifier.SetSystemModuleName(new AssemblyNameInfo("System.Private.CoreLib"));
		var pe = resolver.Main;
		var md = pe.GetMetadataReader();
		var errors = 0;
		// Methods first, then types, as the ilverify CLI does.
		foreach (var h in md.MethodDefinitions) {
			var m = md.GetMethodDefinition(h);
			var where = TypeName(md, m.GetDeclaringType()) + "::" + md.GetString(m.Name);
			foreach (var r in verifier.Verify(pe, h)) {
				Console.WriteLine(where + ": " + Describe(r));
				errors++;
			}
		}
		foreach (var h in md.TypeDefinitions) {
			foreach (var r in verifier.Verify(pe, h, false)) {
				Console.WriteLine(TypeName(md, h) + ": " + Describe(r));
				errors++;
			}
		}
		return errors == 0 ? 0 : 1;
	}

	static string Describe(VerificationResult r) {
		var code = r.Code != VerifierError.None ? r.Code.ToString() : r.ExceptionID?.ToString() ?? "None";
		var s = code + " " + r.Message;
		if (r.ErrorArguments != null && r.ErrorArguments.Length > 0)
			s += " (" + string.Join(", ", r.ErrorArguments.Select(a => a.Name + "=" + a.Value)) + ")";
		return s;
	}

	// References resolve from the shared framework running this tool, then the DLL's own directory.
	sealed class Resolver : IResolver {
		readonly string[] dirs;
		readonly Dictionary<string, PEReader?> cache = new(StringComparer.OrdinalIgnoreCase);
		public readonly PEReader Main;

		public Resolver(string path) {
			dirs = [Path.GetDirectoryName(typeof(object).Assembly.Location)!, Path.GetDirectoryName(path)!];
			Main = new PEReader(File.OpenRead(path));
			cache[Path.GetFileNameWithoutExtension(path)] = Main;
		}

		public PEReader? ResolveAssembly(AssemblyNameInfo name) => Load(name.Name);

		public PEReader? ResolveModule(AssemblyNameInfo referencingAssembly, string fileName) =>
			Load(Path.GetFileNameWithoutExtension(fileName));

		PEReader? Load(string simpleName) {
			if (cache.TryGetValue(simpleName, out var pe)) return pe;
			pe = null;
			foreach (var dir in dirs) {
				var file = Path.Combine(dir, simpleName + ".dll");
				if (File.Exists(file)) {
					pe = new PEReader(File.OpenRead(file));
					break;
				}
			}
			cache[simpleName] = pe;
			return pe;
		}
	}

	static int Dump(string path, string items) {
		using var pe = new PEReader(File.OpenRead(path));
		var md = pe.GetMetadataReader();
		var types = new TypeNames(md);
		foreach (var item in items.Split(',')) {
			switch (item) {
				case "assembly": {
					var a = md.GetAssemblyDefinition();
					Console.WriteLine("assembly " + md.GetString(a.Name) + " " + a.Version);
					break;
				}
				case "refs":
					foreach (var h in md.AssemblyReferences) {
						var r = md.GetAssemblyReference(h);
						Console.WriteLine("assemblyref " + md.GetString(r.Name) + " " + r.Version + " " + Token(md, r));
					}
					break;
				case "entrypoint": {
					var token = pe.PEHeaders.CorHeader!.EntryPointTokenOrRelativeVirtualAddress;
					if (token == 0) {
						Console.WriteLine("entrypoint none");
					} else {
						var m = md.GetMethodDefinition(MetadataTokens.MethodDefinitionHandle(token & 0xFFFFFF));
						Console.WriteLine("entrypoint " + TypeName(md, m.GetDeclaringType()) + "::" + md.GetString(m.Name));
					}
					break;
				}
				default:
					if (!DumpType(md, types, item)) Console.WriteLine("missing " + item);
					break;
			}
		}
		return 0;
	}

	// The public key token, computed when the row holds a full public key.
	static string Token(MetadataReader md, AssemblyReference r) {
		if (r.PublicKeyOrToken.IsNil) return "null";
		var b = md.GetBlobBytes(r.PublicKeyOrToken);
		if (b.Length == 0) return "null";
		if ((r.Flags & AssemblyFlags.PublicKey) != 0) b = SHA1.HashData(b).TakeLast(8).Reverse().ToArray();
		return Convert.ToHexString(b).ToLowerInvariant();
	}

	static bool DumpType(MetadataReader md, TypeNames types, string item) {
		foreach (var h in md.TypeDefinitions) {
			if (TypeName(md, h) != item) continue;
			var t = md.GetTypeDefinition(h);
			var sb = new StringBuilder("type ");
			sb.Append(TypeWords(t.Attributes)).Append(item).Append(GenericNames(md, t.GetGenericParameters()));
			if (!t.BaseType.IsNil) sb.Append(" extends ").Append(types.Of(t.BaseType, default));
			var ifaces = t.GetInterfaceImplementations().Select(i => types.Of(md.GetInterfaceImplementation(i).Interface, default)).ToList();
			if (ifaces.Count > 0) sb.Append(" implements ").Append(string.Join(", ", ifaces));
			Console.WriteLine(sb.ToString());
			var typeArgs = new GenericContext(t.GetGenericParameters(), default);
			foreach (var fh in t.GetFields()) {
				var f = md.GetFieldDefinition(fh);
				var ft = f.DecodeSignature(types, typeArgs);
				Console.WriteLine("  field " + FieldWords(f.Attributes) + ft + " " + md.GetString(f.Name));
			}
			foreach (var mh in t.GetMethods()) {
				var m = md.GetMethodDefinition(mh);
				var sig = m.DecodeSignature(types, new GenericContext(t.GetGenericParameters(), m.GetGenericParameters()));
				Console.WriteLine("  method " + MethodWords(m.Attributes) + sig.ReturnType + " " + md.GetString(m.Name)
					+ GenericNames(md, m.GetGenericParameters()) + "(" + string.Join(", ", sig.ParameterTypes) + ")");
			}
			return true;
		}
		return false;
	}

	static string GenericNames(MetadataReader md, GenericParameterHandleCollection ps) =>
		ps.Count == 0 ? "" : "<" + string.Join(", ", ps.Select(p => md.GetString(md.GetGenericParameter(p).Name))) + ">";

	static string Words(params (bool on, string word)[] words) {
		var sb = new StringBuilder();
		foreach (var (on, word) in words) if (on) sb.Append(word).Append(' ');
		return sb.ToString();
	}

	static string TypeWords(TypeAttributes a) {
		var visibility = (a & TypeAttributes.VisibilityMask) switch {
			TypeAttributes.Public or TypeAttributes.NestedPublic => "public",
			TypeAttributes.NotPublic or TypeAttributes.NestedPrivate => "private",
			TypeAttributes.NestedFamily => "family",
			TypeAttributes.NestedAssembly => "assembly",
			TypeAttributes.NestedFamANDAssem => "famandassem",
			_ => "famorassem",
		};
		return Words((true, visibility),
			((a & TypeAttributes.ClassSemanticsMask) == TypeAttributes.Interface, "interface"),
			((a & TypeAttributes.Abstract) != 0, "abstract"),
			((a & TypeAttributes.Sealed) != 0, "sealed"),
			((a & TypeAttributes.LayoutMask) == TypeAttributes.SequentialLayout, "sequential"),
			((a & TypeAttributes.BeforeFieldInit) != 0, "beforefieldinit"));
	}

	static string MethodWords(MethodAttributes a) {
		var access = (a & MethodAttributes.MemberAccessMask) switch {
			MethodAttributes.Public => "public",
			MethodAttributes.Private => "private",
			MethodAttributes.Family => "family",
			MethodAttributes.Assembly => "assembly",
			MethodAttributes.FamORAssem => "famorassem",
			MethodAttributes.FamANDAssem => "famandassem",
			_ => "privatescope",
		};
		return Words((true, access),
			((a & MethodAttributes.Static) != 0, "static"),
			((a & MethodAttributes.Final) != 0, "final"),
			((a & MethodAttributes.Virtual) != 0, "virtual"),
			((a & MethodAttributes.HideBySig) != 0, "hidebysig"),
			((a & MethodAttributes.VtableLayoutMask) == MethodAttributes.NewSlot, "newslot"),
			((a & MethodAttributes.Abstract) != 0, "abstract"),
			((a & MethodAttributes.SpecialName) != 0, "specialname"),
			((a & MethodAttributes.RTSpecialName) != 0, "rtspecialname"));
	}

	static string FieldWords(FieldAttributes a) {
		var access = (a & FieldAttributes.FieldAccessMask) switch {
			FieldAttributes.Public => "public",
			FieldAttributes.Private => "private",
			FieldAttributes.Family => "family",
			FieldAttributes.Assembly => "assembly",
			FieldAttributes.FamORAssem => "famorassem",
			FieldAttributes.FamANDAssem => "famandassem",
			_ => "privatescope",
		};
		return Words((true, access),
			((a & FieldAttributes.Static) != 0, "static"),
			((a & FieldAttributes.InitOnly) != 0, "initonly"),
			((a & FieldAttributes.Literal) != 0, "literal"));
	}

	// A defined type's full name: ns.Name, or Outer/Inner when nested.
	static string TypeName(MetadataReader md, TypeDefinitionHandle h) {
		var t = md.GetTypeDefinition(h);
		var name = md.GetString(t.Name);
		var outer = t.GetDeclaringType();
		if (!outer.IsNil) return TypeName(md, outer) + "/" + name;
		var ns = md.GetString(t.Namespace);
		return ns == "" ? name : ns + "." + name;
	}

	readonly record struct GenericContext(GenericParameterHandleCollection TypeParams, GenericParameterHandleCollection MethodParams);

	// Types printed ILDasm style.
	sealed class TypeNames(MetadataReader md) : ISignatureTypeProvider<string, GenericContext> {
		public string Of(EntityHandle h, GenericContext ctx) => h.Kind switch {
			HandleKind.TypeDefinition => GetTypeFromDefinition(md, (TypeDefinitionHandle)h, 0),
			HandleKind.TypeReference => GetTypeFromReference(md, (TypeReferenceHandle)h, 0),
			HandleKind.TypeSpecification => GetTypeFromSpecification(md, ctx, (TypeSpecificationHandle)h, 0),
			_ => "?" + h.Kind,
		};

		public string GetPrimitiveType(PrimitiveTypeCode code) => code switch {
			PrimitiveTypeCode.Void => "void",
			PrimitiveTypeCode.Boolean => "bool",
			PrimitiveTypeCode.Char => "char",
			PrimitiveTypeCode.SByte => "int8",
			PrimitiveTypeCode.Byte => "uint8",
			PrimitiveTypeCode.Int16 => "int16",
			PrimitiveTypeCode.UInt16 => "uint16",
			PrimitiveTypeCode.Int32 => "int32",
			PrimitiveTypeCode.UInt32 => "uint32",
			PrimitiveTypeCode.Int64 => "int64",
			PrimitiveTypeCode.UInt64 => "uint64",
			PrimitiveTypeCode.Single => "float32",
			PrimitiveTypeCode.Double => "float64",
			PrimitiveTypeCode.String => "string",
			PrimitiveTypeCode.Object => "object",
			PrimitiveTypeCode.TypedReference => "typedref",
			PrimitiveTypeCode.IntPtr => "native int",
			PrimitiveTypeCode.UIntPtr => "native uint",
			_ => code.ToString(),
		};

		public string GetTypeFromDefinition(MetadataReader reader, TypeDefinitionHandle handle, byte rawTypeKind) =>
			TypeName(reader, handle);

		public string GetTypeFromReference(MetadataReader reader, TypeReferenceHandle handle, byte rawTypeKind) {
			var r = reader.GetTypeReference(handle);
			var name = reader.GetString(r.Name);
			var ns = reader.GetString(r.Namespace);
			var full = ns == "" ? name : ns + "." + name;
			var scope = r.ResolutionScope;
			switch (scope.Kind) {
				case HandleKind.TypeReference:
					return GetTypeFromReference(reader, (TypeReferenceHandle)scope, rawTypeKind) + "/" + name;
				case HandleKind.AssemblyReference:
					return "[" + reader.GetString(reader.GetAssemblyReference((AssemblyReferenceHandle)scope).Name) + "]" + full;
				default:
					return full;
			}
		}

		public string GetTypeFromSpecification(MetadataReader reader, GenericContext ctx, TypeSpecificationHandle handle, byte rawTypeKind) =>
			reader.GetTypeSpecification(handle).DecodeSignature(this, ctx);

		public string GetGenericInstantiation(string genericType, ImmutableArray<string> typeArguments) =>
			genericType + "<" + string.Join(", ", typeArguments) + ">";

		public string GetGenericTypeParameter(GenericContext ctx, int index) => "!" + index;
		public string GetGenericMethodParameter(GenericContext ctx, int index) => "!!" + index;
		public string GetSZArrayType(string elementType) => elementType + "[]";
		public string GetArrayType(string elementType, ArrayShape shape) => elementType + "[" + new string(',', shape.Rank - 1) + "]";
		public string GetByReferenceType(string elementType) => elementType + "&";
		public string GetPointerType(string elementType) => elementType + "*";
		public string GetPinnedType(string elementType) => elementType + " pinned";
		public string GetModifiedType(string modifier, string unmodifiedType, bool isRequired) =>
			unmodifiedType + (isRequired ? " modreq(" : " modopt(") + modifier + ")";
		public string GetFunctionPointerType(MethodSignature<string> signature) =>
			"method " + signature.ReturnType + " *(" + string.Join(", ", signature.ParameterTypes) + ")";
	}
}
