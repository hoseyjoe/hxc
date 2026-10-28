package hxc.codegen.dotnet;

import haxe.io.Bytes;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta.IlConstant;
import hxc.codegen.dotnet.IlMeta.TableIdx as T;
import hxc.codegen.dotnet.MetaTables.CodedIndex;

typedef AssemblyIdentity = {name:String, version:Array<Int>, culture:String, publicKeyToken:Null<Bytes>}

// One output assembly: the heaps, tables and method bodies, added in declaration order, and the
// finished PE image. TypeDef row 1 is `<Module>` and GUID 1 the MVID, which PeWriter fills in.
// Members are added after every TypeDef row, grouped by their type in TypeDef order; finish() points
// each TypeDef at its first field and method. Tokens are a table number in the top byte and a row.

class ModuleBuilder {
	public final heaps = new MetaHeaps();
	public final tables = new MetaTables();
	// Method bodies; a MethodDef's RVA is PeWriter.IL_RVA plus its body's offset here.
	public final il = new IlBytes();

	final name:String;
	final isDll:Bool;
	final mvid:Int;
	final assemblyRefs = new Map<String, Int>();
	// Keyed by IlPaths.key, a signature blob's hex, or parent, name and signature.
	final typeDefs = new Map<String, Int>();
	final typeRefs = new Map<String, Int>();
	final memberRefs = new Map<String, Int>();
	final typeSpecs = new Map<String, Int>();
	final standAloneSigs = new Map<String, Int>();
	final methodSpecs = new Map<String, Int>();
	// The TypeDef row each field and method row belongs to.
	final fieldOwners:Array<Int> = [];
	final methodOwners:Array<Int> = [];

	// The assembly a referenced type comes from; the emitter sets it.
	public var externScope:(IlPath) -> AssemblyIdentity = null;

	public function new(name:String, isDll:Bool) {
		this.name = name;
		this.isDll = isDll;
		var zero = Bytes.alloc(16);
		zero.fill(0, 16, 0);
		mvid = heaps.guids.add(zero);
		tables.typeDef.push([0, heaps.strings.add("<Module>"), 0, 0, 1, 1]);
	}

	// The AssemblyRef row for an assembly, one per name.
	public function assemblyRef(id:AssemblyIdentity):Int {
		var row = assemblyRefs.get(id.name);
		if (row != null) return row;
		var v = id.version;
		tables.assemblyRef.push([
			v[0], v[1], v[2], v[3], 0,
			id.publicKeyToken == null ? 0 : heaps.blobs.add(id.publicKeyToken),
			heaps.strings.add(id.name), heaps.strings.add(id.culture), 0
		]);
		row = tables.assemblyRef.length;
		assemblyRefs.set(id.name, row);
		return row;
	}

	public static inline function row(token:Int):Int return token & 0xFFFFFF;

	public static inline function table(token:Int):Int return token >>> 24;

	// A token as a coded index of the given kind; the token's top byte is its table number.
	public static inline function coded(kind:Int, token:Int):Int return CodedIndex.encode(kind, table(token), row(token));

	// The token a TypeDefOrRef coded index stands for.
	public static function typeDefOrRefToken(c:Int):Int {
		return ([T.ITypeDef, T.ITypeRef, T.ITypeSpec][c & 3] << 24) | (c >> 2);
	}

	// A TypeDef row, its base type set later with setExtends.
	public function typeDef(flags:Int, path:IlPath):Int {
		if (path.nested.length > 0) throw "internal error: nested type definitions are not written";
		if (typeDefs.exists(IlPaths.key(path))) throw "internal error: two type definitions named " + NetConverter.ilpathS(path);
		tables.typeDef.push([flags, heaps.strings.add(path.name), heaps.strings.add(path.ns.join(".")), 0, 0, 0]);
		var token = (T.ITypeDef << 24) | tables.typeDef.length;
		typeDefs.set(IlPaths.key(path), token);
		return token;
	}

	// Whether the assembly being written defines the type.
	public function definesType(path:IlPath):Bool {
		return typeDefs.exists(IlPaths.key(path));
	}

	public function setExtends(typeDefToken:Int, typeDefOrRef:Int):Void {
		tables.typeDef[row(typeDefToken) - 1][3] = typeDefOrRef;
	}

	// Must be added in key order: by type, then by the interface's coded index.
	public function interfaceImpl(typeDefToken:Int, typeDefOrRef:Int):Void {
		tables.interfaceImpl.push([row(typeDefToken), typeDefOrRef]);
	}

	// Makes the method `body` (a MethodDef token) of the type the implementation of `declaration` (a
	// MethodDef or MemberRef token), as C#'s explicit interface implementations are.
	public function methodImpl(typeDefToken:Int, body:Int, declaration:Int):Void {
		tables.methodImpl.push([row(typeDefToken), coded(T.IMethodDefOrRef, body), coded(T.IMethodDefOrRef, declaration)]);
	}

	// A CustomAttribute row on `parent` (a TypeDef, MethodDef, ... token): the attribute's constructor
	// (a MethodDef or MemberRef token) and its value blob. The table is sorted when it is written.
	public function customAttribute(parent:Int, ctor:Int, value:Bytes):Void {
		tables.customAttribute.push([coded(T.IHasCustomAttribute, parent), coded(T.ICustomAttributeType, ctor), heaps.blobs.add(value)]);
	}

	// The Param row `method` (a MethodDef token) made for its parameter `index`, 0 for the first.
	public function paramToken(method:Int, index:Int):Int {
		return (T.IParam << 24) | (tables.methodDef[row(method) - 1][5] + index);
	}

	public function field(owner:Int, flags:Int, name:String, sig:Bytes):Int {
		tables.field.push([flags, heaps.strings.add(name), heaps.blobs.add(sig)]);
		fieldOwners.push(row(owner));
		return (T.IField << 24) | tables.field.length;
	}

	// A MethodDef row with a Param row per name; its body comes later through setBody.
	public function method(owner:Int, flags:Int, implFlags:Int, name:String, sig:Bytes, paramNames:Array<String>):Int {
		tables.methodDef.push([0, implFlags, flags, heaps.strings.add(name), heaps.blobs.add(sig), tables.param.length + 1]);
		methodOwners.push(row(owner));
		for (i in 0...paramNames.length) tables.param.push([0, i + 1, heaps.strings.add(paramNames[i])]);
		return (T.IMethod << 24) | tables.methodDef.length;
	}

	// A Property row of the type `owner` (a TypeDef token), with its PropertyMap row when it is the type's
	// first: must be added grouped by type, in TypeDef order, as each type's properties are one run of rows.
	// `sig` is a SigWriter.property blob.
	public function property(owner:Int, name:String, sig:Bytes):Int {
		var last = tables.propertyMap.length == 0 ? 0 : tables.propertyMap[tables.propertyMap.length - 1][0];
		if (row(owner) < last) throw "internal error: Property rows are not grouped by type";
		tables.property.push([0, heaps.strings.add(name), heaps.blobs.add(sig)]);
		if (row(owner) != last) tables.propertyMap.push([row(owner), tables.property.length]);
		return (T.IProperty << 24) | tables.property.length;
	}

	// A MethodSemantics row making `method` (a MethodDef token) the accessor of `property` (a Property token):
	// Getter 0x0002, Setter 0x0001. The table is sorted by association when it is written.
	public function methodSemantics(semantics:Int, method:Int, property:Int):Void {
		tables.methodSemantics.push([semantics, row(method), coded(T.IHasSemantics, property)]);
	}

	// A fat header must start 4-aligned; a tiny one, whose low two bits are 2, need not.
	public function setBody(method:Int, body:Bytes):Void {
		if (body.get(0) & 3 == 3) il.align(4);
		tables.methodDef[row(method) - 1][0] = PeWriter.IL_RVA + il.length;
		il.bytes(body);
	}

	// A Constant row for a field, parameter or property token; the table is sorted when it is written.
	public function constant(parent:Int, c:IlConstant):Void {
		var b = new IlBytes();
		var type = switch (c) {
			case IBool(v):
				b.u8(v ? 1 : 0);
				0x02;
			case IChar(i):
				b.u16(i);
				0x03;
			case IByte(i):
				b.u8(i);
				0x05;
			case IShort(i):
				b.u16(i & 0xFFFF);
				0x06;
			case IInt(i):
				b.u32(i);
				0x08;
			case IInt64(_, i):
				b.i64(i);
				0x0A;
			case IFloat32(f):
				b.f32(f);
				0x0C;
			case IFloat64(f):
				b.f64(f);
				0x0D;
			case IString(s):
				b.bytes(s);
				0x0E;
			case INull:
				b.u32(0);
				0x12;
		}
		tables.constant.push([type, coded(T.IHasConstant, parent), heaps.blobs.add(b.getBytes())]);
	}

	// Must be added in key order: by owner, then number.
	public function genericParam(owner:Int, number:Int, name:String):Void {
		tables.genericParam.push([number, 0, coded(T.ITypeOrMethodDef, owner), heaps.strings.add(name)]);
	}

	// The TypeDefOrRef coded index of a defined or referenced type. Whether it is a value type is the
	// signature's to say; a TypeRef row does not record it.
	public function typeToken(path:IlPath, valueType:Bool):Int {
		var key = IlPaths.key(path);
		var def = typeDefs.get(key);
		if (def != null) return coded(T.ITypeDefOrRef, def);
		var r = typeRefs.get(key);
		if (r == null) {
			var scope = if (path.nested.length > 0) {
				var outer:IlPath = {ns: path.ns, nested: path.nested.slice(0, path.nested.length - 1), name: path.nested[path.nested.length - 1]};
				CodedIndex.resolutionScope(T.ITypeRef, row(typeDefOrRefToken(typeToken(outer, false))));
			} else {
				CodedIndex.resolutionScope(T.IAssemblyRef, assemblyRef(externScope(path)));
			}
			tables.typeRef.push([scope, heaps.strings.add(path.name), heaps.strings.add(path.nested.length > 0 ? "" : path.ns.join("."))]);
			r = (T.ITypeRef << 24) | tables.typeRef.length;
			typeRefs.set(key, r);
		}
		return coded(T.ITypeDefOrRef, r);
	}

	// A TypeRef of a top-level type in the assembly `scope`, whatever externScope says defines it: the
	// attributes the backend writes on its own are System.Runtime's (AttributesToIl.runtimeAttr). The TypeRef
	// typeToken made already is reused when it has that scope.
	public function typeTokenIn(path:IlPath, scope:AssemblyIdentity):Int {
		var key = IlPaths.key(path);
		var resolution = CodedIndex.resolutionScope(T.IAssemblyRef, assemblyRef(scope));
		var r = typeRefs.get(key);
		if (r != null && tables.typeRef[row(r) - 1][0] == resolution) return coded(T.ITypeDefOrRef, r);
		var pinned = scope.name + "\n" + key;
		r = typeRefs.get(pinned);
		if (r == null) {
			tables.typeRef.push([resolution, heaps.strings.add(path.name), heaps.strings.add(path.ns.join("."))]);
			r = (T.ITypeRef << 24) | tables.typeRef.length;
			typeRefs.set(pinned, r);
			if (!typeRefs.exists(key)) typeRefs.set(key, r);
		}
		return coded(T.ITypeDefOrRef, r);
	}

	public function memberRef(parent:Int, name:String, sig:Bytes):Int {
		var key = parent + " " + name + " " + sig.toHex();
		var r = memberRefs.get(key);
		if (r != null) return r;
		tables.memberRef.push([coded(T.IMemberRefParent, parent), heaps.strings.add(name), heaps.blobs.add(sig)]);
		r = (T.IMemberRef << 24) | tables.memberRef.length;
		memberRefs.set(key, r);
		return r;
	}

	public function typeSpec(sig:Bytes):Int {
		var key = sig.toHex();
		var r = typeSpecs.get(key);
		if (r != null) return r;
		tables.typeSpec.push([heaps.blobs.add(sig)]);
		r = (T.ITypeSpec << 24) | tables.typeSpec.length;
		typeSpecs.set(key, r);
		return r;
	}

	// A generic method's instantiation: `method` is its MethodDef or MemberRef token, `sig` the
	// SigWriter.methodSpec blob of its type arguments.
	public function methodSpec(method:Int, sig:Bytes):Int {
		var key = method + " " + sig.toHex();
		var r = methodSpecs.get(key);
		if (r != null) return r;
		tables.methodSpec.push([coded(T.IMethodDefOrRef, method), heaps.blobs.add(sig)]);
		r = (T.IMethodSpec << 24) | tables.methodSpec.length;
		methodSpecs.set(key, r);
		return r;
	}

	public function userString(s:String):Int {
		return 0x70000000 | heaps.userStrings.add(s);
	}

	public function standAloneSig(sig:Bytes):Int {
		var key = sig.toHex();
		var r = standAloneSigs.get(key);
		if (r != null) return r;
		tables.standAloneSig.push([heaps.blobs.add(sig)]);
		r = (T.IStandAloneSig << 24) | tables.standAloneSig.length;
		standAloneSigs.set(key, r);
		return r;
	}

	// Each TypeDef's field and method lists start at the first row it owns, or where the next type's
	// would.
	function linkMembers(column:Int, owners:Array<Int>, what:String):Void {
		var next = 0;
		for (i in 0...tables.typeDef.length) {
			if (next < owners.length && owners[next] < i + 1) throw "internal error: " + what + " rows are not grouped by type";
			tables.typeDef[i][column] = next + 1;
			while (next < owners.length && owners[next] == i + 1) next++;
		}
		if (next != owners.length) throw "internal error: " + what + " rows are not grouped by type";
	}

	// The image, with `entryPoint` the entry method's MethodDef token, or 0 for none.
	public function finish(entryPoint:Int):Bytes {
		linkMembers(4, fieldOwners, "Field");
		linkMembers(5, methodOwners, "MethodDef");
		tables.module.push([0, heaps.strings.add(name + ".dll"), mvid, 0, 0]);
		// SHA-1 hash algorithm, version 1.0.0.0, no flags or public key, neutral culture.
		tables.assembly.push([0x8004, 1, 0, 0, 0, 0, 0, heaps.strings.add(name), 0]);
		var md = tables.writeMetadata(heaps);
		return PeWriter.write({
			metadata: md.bytes,
			mvidOffset: md.mvidOffset,
			il: il.getBytes(),
			entryPoint: entryPoint,
			isDll: isDll
		});
	}
}
