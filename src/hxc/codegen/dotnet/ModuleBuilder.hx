package hxc.codegen.dotnet;

import haxe.io.Bytes;

typedef AssemblyIdentity = {name:String, version:Array<Int>, culture:String, publicKeyToken:Null<Bytes>}

// One output assembly: the heaps, tables and method bodies, added in declaration order, and the
// finished PE image. TypeDef row 1 is `<Module>` and GUID 1 the MVID, which PeWriter fills in.

class ModuleBuilder {
	public final heaps = new MetaHeaps();
	public final tables = new MetaTables();
	// Method bodies; a MethodDef's RVA is PeWriter.IL_RVA plus its body's offset here.
	public final il = new IlBytes();

	final name:String;
	final isDll:Bool;
	final mvid:Int;
	final assemblyRefs = new Map<String, Int>();

	public function new(name:String, isDll:Bool) {
		this.name = name;
		this.isDll = isDll;
		var zero = Bytes.alloc(16);
		zero.fill(0, 16, 0);
		mvid = heaps.guids.add(zero);
		tables.typeDef.push([0, heaps.strings.add("<Module>"), 0, 0, tables.field.length + 1, tables.methodDef.length + 1]);
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

	// The image, with `entryPoint` the entry method's MethodDef token, or 0 for none.
	public function finish(entryPoint:Int):Bytes {
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
