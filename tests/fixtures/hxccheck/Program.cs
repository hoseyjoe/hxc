// Checks assemblies written by hxc's .NET generator.
//   verify <dll>          ILVerify over method bodies and type definitions
//   dump <dll> <items>    prints the metadata named by a comma-separated item list
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
using ILVerify;

static class Program {
	static int Main(string[] args) {
		if (args.Length == 2 && args[0] == "verify") return Verify(Path.GetFullPath(args[1]));
		if (args.Length == 3 && args[0] == "dump") return Dump(Path.GetFullPath(args[1]), args[2]);
		Console.Error.WriteLine("usage: HxcCheck verify <dll> | dump <dll> <items>");
		return 2;
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
