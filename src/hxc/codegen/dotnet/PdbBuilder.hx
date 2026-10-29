package hxc.codegen.dotnet;

import haxe.io.Bytes;
import hxc.codegen.dotnet.IlMeta.TableIdx as T;
import hxc.codegen.dotnet.MetaTables;

// The Portable PDB of one assembly (https://github.com/dotnet/runtime/blob/main/docs/design/specs/PortablePdb-Metadata.md):
// the debug tables, with their own heaps, and the #Pdb stream that names the DLL's tables they point
// into. MethodDebugInformation row n is MethodDef row n's, so methods are handed over in MethodDef order.

class PdbBuilder {
	// The Sorted mask's high half: LocalScope, StateMachineMethod and CustomDebugInformation.
	static inline var SORTED_HI = (1 << (T.ILocalScope - 32)) | (1 << (T.IStateMachineMethod - 32)) | (1 << (T.ICustomDebugInformation - 32));

	final heaps = new MetaHeaps();

	public function new() {}

	// The debug information of the method whose MethodDef token is `token`, with `localsSig` its
	// StandAloneSig token (0 for none) and `code` its body.
	public function method(token:Int, localsSig:Int, code:IlCode):Void {}

	// The PDB, with `entryPoint` the entry method's MethodDef token or 0, `typeSystemRows` the DLL's
	// row counts by table number and `methodCount` its MethodDef rows. The 20-byte id at `idOffset` is
	// zero, for the caller to derive from the PDB's hash and patch in.
	public function write(entryPoint:Int, typeSystemRows:Array<Int>, methodCount:Int):{bytes:Bytes, idOffset:Int} {
		var methodDebugInformation:Array<Row> = [for (_ in 0...methodCount) [0, 0]];
		// The root scope, with no imports, which every LocalScope row names.
		var importScope:Array<Row> = [[0, 0]];
		var written:Array<{table:Int, rows:Array<Row>, schema:Array<Int>}> = [
			{table: T.IDocument, rows: [], schema: [MetaTables.BLOB, MetaTables.GUID, MetaTables.BLOB, MetaTables.GUID]},
			{table: T.IMethodDebugInformation, rows: methodDebugInformation, schema: [T.IDocument, MetaTables.BLOB]},
			{
				table: T.ILocalScope,
				rows: [],
				schema: [T.IMethod, T.IImportScope, T.ILocalVariable, T.ILocalConstant, MetaTables.U32, MetaTables.U32]
			},
			{table: T.ILocalVariable, rows: [], schema: [MetaTables.U16, MetaTables.U16, MetaTables.STR]},
			{table: T.ILocalConstant, rows: [], schema: [MetaTables.STR, MetaTables.BLOB]},
			{table: T.IImportScope, rows: importScope, schema: [T.IImportScope, MetaTables.BLOB]},
			{table: T.IStateMachineMethod, rows: [], schema: [T.IMethod, T.IMethod]},
			{table: T.ICustomDebugInformation, rows: [], schema: [T.IHasCustomDebugInformation, MetaTables.GUID, MetaTables.BLOB]},
		];
		var rowCounts = typeSystemRows.copy();
		for (w in written) rowCounts[w.table] = w.rows.length;

		// The id, the entry point, then the mask of the DLL's tables with rows and their row counts.
		var pdb = new IlBytes();
		for (_ in 0...20) pdb.u8(0);
		pdb.u32(entryPoint);
		var lo = 0, hi = 0;
		for (t in 0...T.IDocument) {
			if (typeSystemRows[t] == 0) continue;
			if (t < 32) lo |= 1 << t else hi |= 1 << (t - 32);
		}
		pdb.u32(lo);
		pdb.u32(hi);
		for (t in 0...T.IDocument) if (typeSystemRows[t] > 0) pdb.u32(typeSystemRows[t]);

		var root = MetaTables.writeRoot("PDB v1.0", [
			{name: "#Pdb", data: pdb.getBytes()},
			{name: "#~", data: MetaTables.writeTables(written, heaps, rowCounts, 0, SORTED_HI)},
			{name: "#Strings", data: heaps.strings.bytes()},
			{name: "#US", data: heaps.userStrings.bytes()},
			{name: "#GUID", data: heaps.guids.bytes()},
			{name: "#Blob", data: heaps.blobs.bytes()},
		]);
		return {bytes: root.bytes, idOffset: root.offsets["#Pdb"]};
	}
}
