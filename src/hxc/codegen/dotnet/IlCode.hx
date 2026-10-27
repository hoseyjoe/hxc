package hxc.codegen.dotnet;

import haxe.Int64;
import haxe.io.Bytes;

// The opcodes the generator emits (ECMA-335 III); a two-byte opcode is 0xFE00 | its second byte.
class IlOps {
	public static inline var NOP = 0x00;
	public static inline var LDARG_0 = 0x02;
	public static inline var LDLOC_0 = 0x06;
	public static inline var STLOC_0 = 0x0A;
	public static inline var LDARG_S = 0x0E;
	public static inline var LDARGA_S = 0x0F;
	public static inline var STARG_S = 0x10;
	public static inline var LDLOC_S = 0x11;
	public static inline var LDLOCA_S = 0x12;
	public static inline var STLOC_S = 0x13;
	public static inline var LDNULL = 0x14;
	public static inline var LDC_I4_M1 = 0x15;
	public static inline var LDC_I4_0 = 0x16;
	public static inline var LDC_I4_S = 0x1F;
	public static inline var LDC_I4 = 0x20;
	public static inline var LDC_I8 = 0x21;
	public static inline var LDC_R4 = 0x22;
	public static inline var LDC_R8 = 0x23;
	public static inline var DUP = 0x25;
	public static inline var POP = 0x26;
	public static inline var CALL = 0x28;
	public static inline var RET = 0x2A;
	public static inline var BR = 0x38;
	public static inline var BRFALSE = 0x39;
	public static inline var BRTRUE = 0x3A;
	public static inline var BEQ = 0x3B;
	public static inline var BGE = 0x3C;
	public static inline var BGT = 0x3D;
	public static inline var BLE = 0x3E;
	public static inline var BLT = 0x3F;
	public static inline var BNE_UN = 0x40;
	public static inline var LDIND_REF = 0x50;
	public static inline var STIND_REF = 0x51;
	public static inline var ADD = 0x58;
	public static inline var SUB = 0x59;
	public static inline var MUL = 0x5A;
	public static inline var DIV = 0x5B;
	public static inline var DIV_UN = 0x5C;
	public static inline var REM = 0x5D;
	public static inline var REM_UN = 0x5E;
	public static inline var AND = 0x5F;
	public static inline var OR = 0x60;
	public static inline var XOR = 0x61;
	public static inline var SHL = 0x62;
	public static inline var SHR = 0x63;
	public static inline var SHR_UN = 0x64;
	public static inline var NEG = 0x65;
	public static inline var NOT = 0x66;
	public static inline var CONV_I1 = 0x67;
	public static inline var CONV_I2 = 0x68;
	public static inline var CONV_I4 = 0x69;
	public static inline var CONV_I8 = 0x6A;
	public static inline var CONV_R4 = 0x6B;
	public static inline var CONV_R8 = 0x6C;
	public static inline var CONV_U4 = 0x6D;
	public static inline var CONV_U8 = 0x6E;
	public static inline var CALLVIRT = 0x6F;
	public static inline var LDOBJ = 0x71;
	public static inline var LDSTR = 0x72;
	public static inline var NEWOBJ = 0x73;
	public static inline var CASTCLASS = 0x74;
	public static inline var ISINST = 0x75;
	public static inline var THROW = 0x7A;
	public static inline var LDFLD = 0x7B;
	public static inline var LDFLDA = 0x7C;
	public static inline var STFLD = 0x7D;
	public static inline var LDSFLD = 0x7E;
	public static inline var LDSFLDA = 0x7F;
	public static inline var STSFLD = 0x80;
	public static inline var STOBJ = 0x81;
	public static inline var CONV_R_UN = 0x76;
	public static inline var BOX = 0x8C;
	public static inline var NEWARR = 0x8D;
	public static inline var LDLEN = 0x8E;
	public static inline var LDELEM = 0xA3;
	public static inline var STELEM = 0xA4;
	public static inline var UNBOX_ANY = 0xA5;
	public static inline var CONV_U2 = 0xD1;
	public static inline var CONV_U1 = 0xD2;
	public static inline var LDTOKEN = 0xD0;
	public static inline var ENDFINALLY = 0xDC;
	public static inline var LEAVE = 0xDD;
	public static inline var CEQ = 0xFE01;
	public static inline var CGT = 0xFE02;
	public static inline var CGT_UN = 0xFE03;
	public static inline var CLT = 0xFE04;
	public static inline var CLT_UN = 0xFE05;
	public static inline var LDFTN = 0xFE06;
	public static inline var LDVIRTFTN = 0xFE07;
	public static inline var LDARG = 0xFE09;
	public static inline var LDARGA = 0xFE0A;
	public static inline var STARG = 0xFE0B;
	public static inline var LDLOC = 0xFE0C;
	public static inline var LDLOCA = 0xFE0D;
	public static inline var STLOC = 0xFE0E;
	public static inline var VOLATILE = 0xFE13;
	public static inline var INITOBJ = 0xFE15;
	public static inline var RETHROW = 0xFE1A;
}

typedef Label = Int;

// An open protected region: where the block and the current handler start, the handler's kind (0 a
// catch clause, 2 a finally) and caught class, and the clauses of the handlers already ended.
private typedef TryBlock = {start:Int, end:Int, handler:Int, flags:Int, classToken:Int, clauses:Array<Array<Int>>};

// One method's IL: the instruction bytes, the evaluation stack depth after each instruction and its
// maximum, labels with the depth each is reached at, local types and exception clauses. Instructions
// and branches emitted while nothing reaches the code, such as the rest of an expression after a
// `throw` in one of its operands, are dropped, as C# leaves out dead code.

class IlCode {
	// Where a branch's operand is, the end of its instruction, and its target.
	final fixups:Array<{at:Int, end:Int, label:Label}> = [];
	// A label's offset (-1 until marked) and the depth it is reached at (-1 until known).
	final labelPos:Array<Int> = [];
	final labelDepth:Array<Int> = [];
	final tries:Array<TryBlock> = [];
	final clauses:Array<Array<Int>> = [];
	public final what:String;
	final code = new IlBytes();

	public final locals:Array<hxc.codegen.dotnet.IlData.IlSigNorm> = [];

	// -1 after an unconditional transfer, until the next mark.
	public var depth(default, null):Int = 0;
	public var maxStack(default, null):Int = 0;

	// `what` names the method in internal errors.
	public function new(what:String) {
		this.what = what;
	}

	public function newLabel():Label {
		labelPos.push(-1);
		labelDepth.push(-1);
		return labelPos.length - 1;
	}

	public inline function reachable():Bool return depth >= 0;

	function fail(msg:String):Dynamic {
		throw "internal error: " + msg + " in " + what;
	}

	public function mark(l:Label):Void {
		if (labelPos[l] >= 0) fail("label marked twice");
		labelPos[l] = code.length;
		var d = labelDepth[l];
		if (depth >= 0) {
			if (d >= 0 && d != depth) fail("stack depth " + depth + " meets " + d + " at a label");
			labelDepth[l] = depth;
		} else if (d >= 0) {
			// Reached only by forward branches, at their depth.
			depth = d;
		}
		// Else nothing reaches it yet: a backward branch to it could only come from the dead code after
		// it, so that stays dead.
	}

	// Whether a branch already goes to the label.
	public inline function targeted(l:Label):Bool return labelDepth[l] >= 0;

	// Marks the label unless nothing reaches it, so code after a transfer stays unreachable.
	public function markIfUsed(l:Label):Void {
		if (depth >= 0 || labelDepth[l] >= 0) mark(l);
	}

	// Recovery after a user-code statement failed to lower: its IL is thrown away, so the stack is
	// put back to where the statement started.
	public function resetDepth(d:Int):Void {
		depth = d;
	}

	function opcode(code:Int):Void {
		if (code > 0xFF) {
			this.code.u8(0xFE);
			this.code.u8(code & 0xFF);
		} else {
			this.code.u8(code);
		}
	}

	function stack(pops:Int, pushes:Int):Void {
		if (depth < pops) fail("stack underflow");
		depth += pushes - pops;
		if (depth > maxStack) maxStack = depth;
	}

	// After these, nothing falls through.
	function transfers(code:Int):Bool {
		return code == IlOps.BR || code == IlOps.LEAVE || code == IlOps.RET || code == IlOps.THROW || code == IlOps.RETHROW
			|| code == IlOps.ENDFINALLY;
	}

	public function op(code:Int, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		if (transfers(code)) depth = -1;
	}

	public function opI32(code:Int, v:Int, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.u32(v);
	}

	function opI8(code:Int, v:Int, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.u8(v);
	}

	function opU16(code:Int, v:Int, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.u16(v);
	}

	public function opI64(code:Int, v:Int64, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.i64(v);
	}

	public function opR8(code:Int, v:Float, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.f64(v);
	}

	public function opR4(code:Int, v:Float, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.f32(v);
	}

	// ldelem for an array of `elem`: the typed short form C# emits for a primitive (ILVerify rejects the
	// token form for Char and Boolean), the token form otherwise; `token` is called only then.
	public function ldelem(elem:hxc.codegen.dotnet.IlData.IlSigNorm, token:() -> Int):Void {
		var short = switch (elem) {
			case LInt8: 0x90;
			case LBool | LUInt8: 0x91;
			case LInt16: 0x92;
			case LChar | LUInt16: 0x93;
			case LInt32: 0x94;
			case LUInt32: 0x95;
			case LInt64 | LUInt64: 0x96;
			case LIntPtr | LUIntPtr: 0x97;
			case LFloat32: 0x98;
			case LFloat64: 0x99;
			case _: -1;
		}
		if (short >= 0) op(short, 2, 1) else opToken(IlOps.LDELEM, token(), 2, 1);
	}

	// stelem for an array of `elem`, as ldelem.
	public function stelem(elem:hxc.codegen.dotnet.IlData.IlSigNorm, token:() -> Int):Void {
		var short = switch (elem) {
			case LIntPtr | LUIntPtr: 0x9B;
			case LBool | LInt8 | LUInt8: 0x9C;
			case LChar | LInt16 | LUInt16: 0x9D;
			case LInt32 | LUInt32: 0x9E;
			case LInt64 | LUInt64: 0x9F;
			case LFloat32: 0xA0;
			case LFloat64: 0xA1;
			case _: -1;
		}
		if (short >= 0) op(short, 3, 0) else opToken(IlOps.STELEM, token(), 3, 0);
	}

	public function opToken(code:Int, token:Int, pops:Int, pushes:Int):Void {
		if (depth < 0) return;
		stack(pops, pushes);
		opcode(code);
		this.code.u32(token);
		if (transfers(code)) depth = -1;
	}

	// Always the long form. A conditional branch pops its operands; `leave` empties the stack.
	public function branch(code:Int, l:Label):Void {
		if (depth < 0) return;
		var pops = switch (code) {
			case IlOps.BR | IlOps.LEAVE: 0;
			case IlOps.BRFALSE | IlOps.BRTRUE: 1;
			case _: 2;
		}
		stack(pops, 0);
		if (code == IlOps.LEAVE) depth = 0;
		var d = labelDepth[l];
		// The code after a label marked while nothing reached it was dropped, so its offset is wrong.
		if (labelPos[l] >= 0 && d < 0) fail("a branch back to an unreached label");
		if (d >= 0 && d != depth) fail("stack depth " + depth + " meets " + d + " at a branch");
		labelDepth[l] = depth;
		opcode(code);
		fixups.push({at: this.code.length, end: this.code.length + 4, label: l});
		this.code.u32(0);
		if (transfers(code)) depth = -1;
	}

	public function ldarg(i:Int):Void {
		if (i < 4) op(IlOps.LDARG_0 + i, 0, 1) else if (i < 256) opI8(IlOps.LDARG_S, i, 0, 1) else opU16(IlOps.LDARG, i, 0, 1);
	}

	public function ldarga(i:Int):Void {
		if (i < 256) opI8(IlOps.LDARGA_S, i, 0, 1) else opU16(IlOps.LDARGA, i, 0, 1);
	}

	public function starg(i:Int):Void {
		if (i < 256) opI8(IlOps.STARG_S, i, 1, 0) else opU16(IlOps.STARG, i, 1, 0);
	}

	public function ldloc(i:Int):Void {
		if (i < 4) op(IlOps.LDLOC_0 + i, 0, 1) else if (i < 256) opI8(IlOps.LDLOC_S, i, 0, 1) else opU16(IlOps.LDLOC, i, 0, 1);
	}

	public function stloc(i:Int):Void {
		if (i < 4) op(IlOps.STLOC_0 + i, 1, 0) else if (i < 256) opI8(IlOps.STLOC_S, i, 1, 0) else opU16(IlOps.STLOC, i, 1, 0);
	}

	public function ldloca(i:Int):Void {
		if (i < 256) opI8(IlOps.LDLOCA_S, i, 0, 1) else opU16(IlOps.LDLOCA, i, 0, 1);
	}

	public function ldcI4(v:Int):Void {
		if (v >= -1 && v <= 8) op(IlOps.LDC_I4_0 + v, 0, 1) else if (v >= -128 && v <= 127) opI8(IlOps.LDC_I4_S, v & 0xFF, 0, 1)
		else opI32(IlOps.LDC_I4, v, 0, 1);
	}

	public function addLocal(t:hxc.codegen.dotnet.IlData.IlSigNorm):Int {
		locals.push(t);
		return locals.length - 1;
	}

	// A try block starts on an empty stack and ends with a `leave` the caller emits.
	public function beginTry():Void {
		if (depth != 0) fail("a try block entered with a non-empty stack");
		tries.push({start: code.length, end: -1, handler: -1, flags: 0, classToken: 0, clauses: []});
	}

	// Ends the try block or the previous handler and starts a handler, which has the exception on the
	// stack.
	public function beginCatch(classToken:Int):Void {
		var t = tries[tries.length - 1];
		if (t == null) fail("a catch outside a try");
		closeHandler(t);
		if (t.end < 0) t.end = code.length;
		t.handler = code.length;
		t.flags = 0;
		t.classToken = classToken;
		if (depth >= 0) fail("a try block or handler that falls through");
		depth = 1;
		if (maxStack < 1) maxStack = 1;
	}

	// Ends the try block and starts its finally handler, which starts on an empty stack and ends with
	// `endfinally`. A try block with a finally handler has no other handler.
	public function beginFinally():Void {
		var t = tries[tries.length - 1];
		if (t == null) fail("a finally outside a try");
		if (t.end >= 0) fail("a finally after another handler");
		t.end = code.length;
		t.handler = code.length;
		t.flags = 2;
		t.classToken = 0;
		if (depth >= 0) fail("a try block that falls through");
		depth = 0;
	}

	function closeHandler(t:TryBlock):Void {
		if (t.handler < 0) return;
		t.clauses.push([t.flags, t.start, t.end - t.start, t.handler, code.length - t.handler, t.classToken]);
		t.handler = -1;
	}

	// How many try blocks are open, for `abandonTries`.
	public var openTries(get, never):Int;

	inline function get_openTries():Int return tries.length;

	// Recovery after a user-code statement failed to lower inside try blocks it opened: they are closed
	// without clauses, as the method's IL is not written.
	public function abandonTries(open:Int):Void {
		while (tries.length > open) tries.pop();
	}

	// Inner clauses come first in the table, so a try's clauses are added when it ends.
	public function endTry():Void {
		var t = tries.pop();
		if (t == null) fail("endTry outside a try");
		if (depth >= 0) fail("a handler that falls through");
		closeHandler(t);
		for (c in t.clauses) clauses.push(c);
	}

	// The method body: a tiny header when it can be, else a fat one with its exception clauses.
	public function body(localsToken:Int):Bytes {
		if (tries.length > 0) fail("an unclosed try block");
		for (f in fixups) {
			var target = labelPos[f.label];
			if (target < 0) fail("a branch to an unmarked label");
			code.patchU32(f.at, target - f.end);
		}
		var b = new IlBytes();
		var il = code.getBytes();
		if (il.length < 64 && maxStack <= 8 && locals.length == 0 && clauses.length == 0) {
			b.u8((il.length << 2) | 0x2);
			b.bytes(il);
			return b.getBytes();
		}
		b.u16(clauses.length > 0 ? 0x301B : 0x3013);
		b.u16(maxStack);
		b.u32(il.length);
		b.u32(localsToken);
		b.bytes(il);
		if (clauses.length > 0) {
			b.align(4);
			var size = clauses.length * 24 + 4;
			b.u8(0x41);
			b.u8(size & 0xFF);
			b.u8((size >> 8) & 0xFF);
			b.u8((size >> 16) & 0xFF);
			for (c in clauses) for (v in c) b.u32(v);
		}
		return b.getBytes();
	}
}
