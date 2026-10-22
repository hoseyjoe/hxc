package hxc.codegen.dotnet;

import haxe.io.Bytes;
import hxc.codegen.dotnet.IlMeta.TableIdx as T;

// The metadata tables the generator writes (ECMA-335 II.22) and the #~ stream and metadata root that
// hold them (II.24.2.1, II.24.2.6). A row is its column values in schema order: plain numbers, heap
// indices, 1-based row indices, and coded indices already encoded with CodedIndex.
typedef Row = Array<Int>;

// The coded index kinds a written table uses (II.24.2.6), numbered as in TableIdx.
class CodedIndex {
	// Tag order is the table order of each kind; -1 marks an unused tag.
	static final typeDefOrRefTables = [T.ITypeDef, T.ITypeRef, T.ITypeSpec];
	static final hasCustomAttributeTables = [
		T.IMethod, T.IField, T.ITypeRef, T.ITypeDef, T.IParam, T.IInterfaceImpl, T.IMemberRef, T.IModule, T.IDeclSecurity,
		T.IProperty, T.IEvent, T.IStandAloneSig, T.IModuleRef, T.ITypeSpec, T.IAssembly, T.IAssemblyRef, T.IFile,
		T.IExportedType, T.IManifestResource, T.IGenericParam, T.IGenericParamConstraint, T.IMethodSpec
	];
	static final memberRefParentTables = [T.ITypeDef, T.ITypeRef, T.IModuleRef, T.IMethod, T.ITypeSpec];
	static final methodDefOrRefTables = [T.IMethod, T.IMemberRef];
	static final customAttributeTypeTables = [-1, -1, T.IMethod, T.IMemberRef, -1];
	static final resolutionScopeTables = [T.IModule, T.IModuleRef, T.IAssemblyRef, T.ITypeRef];
	static final typeOrMethodDefTables = [T.ITypeDef, T.IMethod];

	public static function tables(kind:Int):Array<Int> {
		return switch (kind) {
			case T.ITypeDefOrRef: typeDefOrRefTables;
			case T.IHasCustomAttribute: hasCustomAttributeTables;
			case T.IMemberRefParent: memberRefParentTables;
			case T.IMethodDefOrRef: methodDefOrRefTables;
			case T.ICustomAttributeType: customAttributeTypeTables;
			case T.IResolutionScope: resolutionScopeTables;
			case T.ITypeOrMethodDef: typeOrMethodDefTables;
			case _: throw "unsupported coded index " + kind;
		}
	}

	public static function tagBits(kind:Int):Int {
		var n = tables(kind).length - 1;
		var bits = 0;
		while (n > 0) {
			bits++;
			n >>= 1;
		}
		return bits;
	}

	public static function encode(kind:Int, table:Int, row:Int):Int {
		var tag = tables(kind).indexOf(table);
		if (tag < 0) throw "table " + table + " is not in coded index " + kind;
		return (row << tagBits(kind)) | tag;
	}

	public static inline function typeDefOrRef(table:Int, row:Int):Int return encode(T.ITypeDefOrRef, table, row);

	public static inline function hasCustomAttribute(table:Int, row:Int):Int return encode(T.IHasCustomAttribute, table, row);

	public static inline function memberRefParent(table:Int, row:Int):Int return encode(T.IMemberRefParent, table, row);

	public static inline function methodDefOrRef(table:Int, row:Int):Int return encode(T.IMethodDefOrRef, table, row);

	public static inline function customAttributeType(table:Int, row:Int):Int return encode(T.ICustomAttributeType, table, row);

	public static inline function resolutionScope(table:Int, row:Int):Int return encode(T.IResolutionScope, table, row);

	public static inline function typeOrMethodDef(table:Int, row:Int):Int return encode(T.ITypeOrMethodDef, table, row);
}

class MetaTables {
	// Column kinds besides a table number (a row index into it) or a coded index kind.
	static inline var U16 = -1;
	static inline var U32 = -2;
	static inline var STR = -3;
	static inline var GUID = -4;
	static inline var BLOB = -5;

	// The Sorted mask: every table that ECMA-335 keeps sorted by its key column.
	static inline var SORTED_LO = 0x3301FA00;
	static inline var SORTED_HI = 0x1600;

	public final module:Array<Row> = [];
	public final typeRef:Array<Row> = [];
	public final typeDef:Array<Row> = [];
	public final field:Array<Row> = [];
	public final methodDef:Array<Row> = [];
	public final param:Array<Row> = [];
	public final interfaceImpl:Array<Row> = [];
	public final memberRef:Array<Row> = [];
	public final customAttribute:Array<Row> = [];
	public final standAloneSig:Array<Row> = [];
	public final typeSpec:Array<Row> = [];
	public final assembly:Array<Row> = [];
	public final assemblyRef:Array<Row> = [];
	public final genericParam:Array<Row> = [];
	public final methodSpec:Array<Row> = [];
	public final genericParamConstraint:Array<Row> = [];

	// In table number order, which is the order the #~ stream holds them.
	final written:Array<{table:Int, rows:Array<Row>, schema:Array<Int>}>;

	public function new() {
		written = [
			{table: T.IModule, rows: module, schema: [U16, STR, GUID, GUID, GUID]},
			{table: T.ITypeRef, rows: typeRef, schema: [T.IResolutionScope, STR, STR]},
			{table: T.ITypeDef, rows: typeDef, schema: [U32, STR, STR, T.ITypeDefOrRef, T.IField, T.IMethod]},
			{table: T.IField, rows: field, schema: [U16, STR, BLOB]},
			{table: T.IMethod, rows: methodDef, schema: [U32, U16, U16, STR, BLOB, T.IParam]},
			{table: T.IParam, rows: param, schema: [U16, U16, STR]},
			{table: T.IInterfaceImpl, rows: interfaceImpl, schema: [T.ITypeDef, T.ITypeDefOrRef]},
			{table: T.IMemberRef, rows: memberRef, schema: [T.IMemberRefParent, STR, BLOB]},
			{table: T.ICustomAttribute, rows: customAttribute, schema: [T.IHasCustomAttribute, T.ICustomAttributeType, BLOB]},
			{table: T.IStandAloneSig, rows: standAloneSig, schema: [BLOB]},
			{table: T.ITypeSpec, rows: typeSpec, schema: [BLOB]},
			{table: T.IAssembly, rows: assembly, schema: [U32, U16, U16, U16, U16, U32, BLOB, STR, STR]},
			{table: T.IAssemblyRef, rows: assemblyRef, schema: [U16, U16, U16, U16, U32, BLOB, STR, STR, BLOB]},
			{table: T.IGenericParam, rows: genericParam, schema: [U16, U16, T.ITypeOrMethodDef, STR]},
			{table: T.IMethodSpec, rows: methodSpec, schema: [T.IMethodDefOrRef, BLOB]},
			{table: T.IGenericParamConstraint, rows: genericParamConstraint, schema: [T.IGenericParam, T.ITypeDefOrRef]},
		];
	}

	static function compareBy(a:Row, b:Row, columns:Array<Int>):Int {
		for (c in columns) if (a[c] != b[c]) return a[c] < b[c] ? -1 : 1;
		return 0;
	}

	// Stable, so rows with equal keys keep the order they were added in.
	static function sortBy(rows:Array<Row>, columns:Array<Int>):Void {
		haxe.ds.ArraySort.sort(rows, (a, b) -> compareBy(a, b, columns));
	}

	// Tables whose row numbers other rows point at cannot be reordered here, so they must be added in
	// key order.
	static function checkSorted(name:String, rows:Array<Row>, columns:Array<Int>):Void {
		for (i in 1...rows.length)
			if (compareBy(rows[i - 1], rows[i], columns) > 0) throw "internal error: " + name + " rows are not in key order";
	}

	public function writeMetadata(h:MetaHeaps):{bytes:Bytes, mvidOffset:Int} {
		// Nothing points at a CustomAttribute row, so that table alone is sorted here.
		sortBy(customAttribute, [0]);
		checkSorted("InterfaceImpl", interfaceImpl, [0, 1]);
		checkSorted("GenericParam", genericParam, [2, 0]);
		checkSorted("GenericParamConstraint", genericParamConstraint, [0]);

		var rowCounts = [for (_ in 0...64) 0];
		for (w in written) rowCounts[w.table] = w.rows.length;
		function width(kind:Int):Int {
			return switch (kind) {
				case U16: 2;
				case U32: 4;
				case STR: h.strings.isLarge() ? 4 : 2;
				case GUID: h.guids.isLarge() ? 4 : 2;
				case BLOB: h.blobs.isLarge() ? 4 : 2;
				case k if (k >= 64):
					var limit = 1 << (16 - CodedIndex.tagBits(k));
					var w = 2;
					for (t in CodedIndex.tables(k)) if (t >= 0 && rowCounts[t] >= limit) w = 4;
					w;
				case t: rowCounts[t] < 0x10000 ? 2 : 4;
			}
		}

		var s = new IlBytes();
		s.u32(0);
		s.u8(2);
		s.u8(0);
		s.u8((h.strings.isLarge() ? 0x01 : 0) | (h.guids.isLarge() ? 0x02 : 0) | (h.blobs.isLarge() ? 0x04 : 0));
		s.u8(1);
		var validLo = 0, validHi = 0;
		for (w in written) {
			if (w.rows.length == 0) continue;
			if (w.table < 32) validLo |= 1 << w.table else validHi |= 1 << (w.table - 32);
		}
		s.u32(validLo);
		s.u32(validHi);
		s.u32(SORTED_LO);
		s.u32(SORTED_HI);
		for (w in written) if (w.rows.length > 0) s.u32(w.rows.length);
		for (w in written) {
			var widths = [for (k in w.schema) width(k)];
			for (r in w.rows) {
				if (r.length != widths.length) throw "table " + w.table + ": a row has " + r.length + " columns";
				for (i in 0...widths.length) {
					if (widths[i] == 4) {
						s.u32(r[i]);
					} else {
						if (r[i] < 0 || r[i] > 0xFFFF) throw "table " + w.table + ": column " + i + " does not fit 2 bytes";
						s.u16(r[i]);
					}
				}
			}
		}
		s.align(4);

		var streams = [
			{name: "#~", data: s.getBytes()},
			{name: "#Strings", data: h.strings.bytes()},
			{name: "#US", data: h.userStrings.bytes()},
			{name: "#GUID", data: h.guids.bytes()},
			{name: "#Blob", data: h.blobs.bytes()},
		];
		// Each stream header is an offset, a size and the name, null-terminated and padded to 4.
		var offset = 32;
		for (st in streams) offset += 8 + ((st.name.length + 4) & ~3);
		var root = new IlBytes();
		root.u32(0x424A5342);
		root.u16(1);
		root.u16(1);
		root.u32(0);
		root.u32(12);
		root.bytes(Bytes.ofString("v4.0.30319"));
		root.align(4);
		root.u16(0);
		root.u16(streams.length);
		var guidOffset = 0;
		for (st in streams) {
			if (st.name == "#GUID") guidOffset = offset;
			root.u32(offset);
			root.u32(st.data.length);
			root.bytes(Bytes.ofString(st.name));
			root.u8(0);
			root.align(4);
			offset += st.data.length;
		}
		for (st in streams) root.bytes(st.data);
		if (module.length != 1) throw "the Module table needs exactly one row";
		return {bytes: root.getBytes(), mvidOffset: guidOffset + (module[0][2] - 1) * 16};
	}
}
