package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.core.Globals;
import hxc.core.TexprTools;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.OverloadResolution;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.ExternMembers;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta;
import hxc.codegen.dotnet.TclassToIl.ClassPlan;
import hxc.codegen.dotnet.TclassToIl.MethodPlan;
import hxc.codegen.dotnet.TexprToIl.Place;
import hxc.codegen.dotnet.TexprToIl.Ret;
import hxc.codegen.dotnet.TexprToIl.Slot;
import hxc.codegen.dotnet.TexprToIl.SpillMode;
import hxc.codegen.dotnet.TexprToIl.constInt;
import hxc.codegen.dotnet.TexprToIl.isExtern;
import hxc.codegen.dotnet.TexprToIl.isIntLike;
import hxc.codegen.dotnet.TexprToIl.isNullConst;
import hxc.codegen.dotnet.TexprToIl.isNumeric;
import hxc.codegen.dotnet.TexprToIl.isReference;
import hxc.codegen.dotnet.TexprToIl.isStringClass;
import hxc.codegen.dotnet.TexprToIl.isTypeParam;
import hxc.codegen.dotnet.TexprToIl.needVal;
import hxc.codegen.dotnet.TexprToIl.strip;

// The operators of TexprToIl: arithmetic, comparison, boolean conditions, increments and compound
// assignment, and string concatenation. Shares its state through the TexprToIl that owns it.
@:allow(hxc.codegen.dotnet.TexprToIl, hxc.codegen.dotnet.TexprFlow, hxc.codegen.dotnet.TexprCalls, hxc.codegen.dotnet.TexprDynamic)
class TexprOps {
	final tl:TexprToIl;
	final g:DotnetCtx;
	final code:IlCode;

	public function new(tl:TexprToIl) {
		this.tl = tl;
		g = tl.g;
		code = tl.code;
	}

	function binary(ret:Ret, e:TExpr, op:Binop, e1:TExpr, e2:TExpr):Void {
		// An operator with a Dynamic operand goes through haxe.lang.Runtime.
		if (tl.dyn.binop(ret, e, op, e1, e2)) return;
		switch (op) {
			case OpBoolAnd | OpBoolOr:
				boolValue(ret, e);
			case OpEq | OpNotEq | OpLt | OpLte | OpGt | OpGte:
				compare(ret, op, e1, e2);
			case OpAdd if (tl.sig(e.type).match(LString)):
				pushString(e1);
				pushString(e2);
				concat();
				tl.coerce(LString, ret);
			case OpAdd | OpSub | OpMult | OpDiv | OpMod | OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr:
				var s1 = tl.operandSig(op, e1), s2 = tl.operandSig(op, e2);
				// A Null<T> result is computed in T and wrapped again, as HardNullableSynf does.
				var own = tl.sig(e.type);
				var t = tl.unNull(own);
				// Bitwise operators and shifts take Int operands only.
				if (!isArith(op) && !(isIntLike(s1) && isIntLike(s2) && isIntLike(t)))
					throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
				// `+` is the operator HardNullableSynf unwraps itself; the others gencs casts first.
				var add = op.match(OpAdd);
				if (add) tl.nullOperand(RValue(t), e1) else tl.texpr(RValue(t), e1);
				numericTail(op, t, e2, s1, true, add);
				tl.dyn.finish(t, own, ret);
			case _:
				throw new Unsupported("the " + Ast.sBinop(op) + " operator", false);
		}
	}

	static function isArith(op:Binop):Bool return op.match(OpAdd | OpSub | OpMult | OpDiv | OpMod);

	// C# promotes a UInt and an Int operand to long: their comparisons and remainder are a long's.
	static function mixesUIntAndInt(s1:IlSigNorm, s2:IlSigNorm):Bool {
		return isIntLike(s1) && isIntLike(s2) && !IlPaths.sigEq(s1, s2);
	}

	// The int32 on the stack, of type `s`, as a long.
	function widen(s:IlSigNorm):Void {
		code.op(s.match(LUInt32) ? IlOps.CONV_U8 : IlOps.CONV_I8, 1, 1);
	}

	// The left operand, of type `t` on the stack and `left` as typed, is there; this pushes the right
	// one and applies `op`. A compound assignment does not promote: gencs casts its right side to the
	// left's type, so the left type's own remainder applies.
	// `keepNull`: the right operand is one HardNullableSynf unwraps itself (TexprToIl.nullOperand).
	function numericTail(op:Binop, t:IlSigNorm, e2:TExpr, left:IlSigNorm, promote = true, keepNull = false):Void {
		var bad = new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
		if (!isNumeric(t)) throw bad;
		if (!isArith(op) && !isIntLike(t)) throw bad;
		var unsigned = t.match(LUInt32);
		if (op.match(OpDiv) && !t.match(LFloat64)) throw bad;
		var right = promote && op.match(OpMod) && isIntLike(t) ? tl.sig(e2.type) : null;
		if (right != null && mixesUIntAndInt(left, right)) {
			// gencs casts the long remainder back to the result type.
			widen(left);
			tl.texpr(RValue(right), e2);
			widen(right);
			code.op(IlOps.REM, 2, 1);
			code.op(IlOps.CONV_I4, 1, 1);
			return;
		}
		switch (op) {
			case OpShl | OpShr | OpUShr:
				// The count is masked as C# does.
				var n = constInt(e2);
				if (n != null) {
					code.ldcI4(n & 31);
				} else {
					tl.texpr(RValue(LInt32), e2);
					code.ldcI4(31);
					code.op(IlOps.AND, 2, 1);
				}
				code.op(op.match(OpShl) ? IlOps.SHL : op.match(OpShr) && !unsigned ? IlOps.SHR : IlOps.SHR_UN, 2, 1);
			case _:
				if (keepNull) tl.nullOperand(RValue(t), e2) else tl.texpr(RValue(t), e2);
				code.op(switch (op) {
					case OpAdd: IlOps.ADD;
					case OpSub: IlOps.SUB;
					case OpMult: IlOps.MUL;
					case OpDiv: IlOps.DIV;
					case OpMod: unsigned ? IlOps.REM_UN : IlOps.REM;
					case OpAnd: IlOps.AND;
					case OpOr: IlOps.OR;
					case OpXor: IlOps.XOR;
					case _: throw bad;
				}, 2, 1);
		}
	}

	function not():Void {
		code.ldcI4(0);
		code.op(IlOps.CEQ, 2, 1);
	}

	// haxe.lang.Runtime.undefined, the value `__hx_getField` gives for a missing field when asked to check.
	static function isUndefined(e:TExpr):Bool {
		return switch (strip(e).expr) {
			case TField(_, FStatic(c, cf)): cf.name == "undefined" && DotnetTypes.haxePath(TClassDecl(c)) == "cs.internal.Runtime";
			case TIdent("__undefined__"): true;
			case _: false;
		}
	}

	function compare(ret:Ret, op:Binop, e1:TExpr, e2:TExpr):Void {
		var equality = op.match(OpEq | OpNotEq);
		var isFloat = false;
		// Two UInt operands compare unsigned; a UInt and an Int compare as longs, as in C#.
		var unsigned = false;
		var string = false;
		var netOperator = null;
		if (isNullConst(e1) || isNullConst(e2)) {
			if (!equality) throw new Unsupported("comparing null with the " + Ast.sBinop(op) + " operator", false);
			var other = isNullConst(e1) ? e2 : e1;
			if (isNullConst(other)) throw new Unsupported("comparing null with null", false);
			var s = tl.sig(other.type);
			if (tl.isHaxeNull(s)) {
				// `x == null` on a haxe.lang.Null<T> is `!x.hasValue`.
				tl.texpr(RValue(s), other);
				tl.loadNullField(s, "hasValue");
				if (op.match(OpEq)) not();
				tl.coerce(LBool, ret);
				return;
			}
			if (DotnetTypes.isValueType(s) || isTypeParam(s)) throw new Unsupported("comparing a value type with null", false);
			netOperator = equalityOperator(op, e1, e2);
			tl.texpr(RValue(netOperator == null ? null : netOperator.args[0]), e1);
			tl.texpr(RValue(netOperator == null ? null : netOperator.args[1]), e2);
		} else {
			// Null<T> operands compare their values, as HardNullableSynf unwraps them; Char and the small
			// integers compare as Ints, as C# promotes them.
			inline function operand(e:TExpr) return switch (tl.unNull(tl.sig(e.type))) {
				case LChar | LInt8 | LUInt8 | LInt16 | LUInt16: LInt32;
				case s: s;
			}
			var s1 = operand(e1), s2 = operand(e2);
			var idx1 = TexprToIl.externEnumIndex(e1), idx2 = TexprToIl.externEnumIndex(e2);
			if (equality && (idx1 != null && constInt(e2) != null || idx2 != null && constInt(e1) != null)) {
				// enumIndex(x) == i on a .NET enum: x against the value of the constructor at i.
				var x = idx1 != null ? idx1 : idx2;
				tl.texpr(RValue(tl.sig(x.value.type)), x.value);
				tl.calls.externEnumLiteral(x.en, TexprToIl.enumFieldAt(x.en, idx1 != null ? constInt(e2) : constInt(e1)));
			} else if (mixesUIntAndInt(s1, s2)) {
				tl.nullOperand(RValue(s1), e1);
				widen(s1);
				tl.nullOperand(RValue(s2), e2);
				widen(s2);
			} else if (isNumeric(s1) && isNumeric(s2)) {
				var t = s1.match(LFloat64) || s2.match(LFloat64) ? LFloat64 : s1.match(LUInt32) || s2.match(LUInt32) ? LUInt32 : LInt32;
				isFloat = t.match(LFloat64);
				unsigned = t.match(LUInt32);
				tl.nullOperand(RValue(t), e1);
				tl.nullOperand(RValue(t), e2);
			} else if (equality && (TexprToIl.clrEnum(e1.type) != null && TexprToIl.clrEnum(e1.type) == TexprToIl.clrEnum(e2.type)
				|| TexprToIl.externEnum(e1.type) != null && TexprToIl.externEnum(e1.type) == TexprToIl.externEnum(e2.type))) {
				// Two values of one CLR enum compare as their indices, two of a .NET enum as their values.
				tl.texpr(RValue(s1), e1);
				tl.texpr(RValue(s2), e2);
			} else if (s1.match(LInt64) && s2.match(LInt64) || s1.match(LUInt64) && s2.match(LUInt64)) {
				// Two Int64 or two UInt64 values, as C# compares longs.
				unsigned = s1.match(LUInt64);
				tl.texpr(RValue(s1), e1);
				tl.texpr(RValue(s2), e2);
			} else if (equality && s1.match(LValueType(_, _)) && IlPaths.sigEq(s1, s2) && TexprToIl.externEnum(e1.type) == null) {
				// Two .NET structs of one type, such as System.Decimal, through the operator C# binds.
				netOperator = equalityOperator(op, e1, e2);
				if (netOperator == null) throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
				tl.texpr(RValue(netOperator.args[0]), e1);
				tl.texpr(RValue(netOperator.args[1]), e2);
			} else if (equality && s1.match(LBool) && s2.match(LBool)) {
				tl.texpr(RValue(LBool), e1);
				tl.texpr(RValue(LBool), e2);
			} else if (equality && s1.match(LString) && s2.match(LString)) {
				string = true;
				tl.texpr(RValue(LString), e1);
				tl.texpr(RValue(LString), e2);
			} else if (equality && (isUndefined(e1) || isUndefined(e2))) {
				// gencs leaves a comparison with Runtime.undefined C#'s reference comparison.
				tl.texpr(RValue(LObject), e1);
				tl.texpr(RValue(LObject), e2);
			} else if (equality && isReference(s1) && isReference(s2) && !s1.match(LObject) && !s2.match(LObject)) {
				netOperator = equalityOperator(op, e1, e2);
				tl.texpr(RValue(netOperator == null ? null : netOperator.args[0]), e1);
				tl.texpr(RValue(netOperator == null ? null : netOperator.args[1]), e2);
			} else {
				throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
			}
		}
		if (netOperator != null) {
			code.opToken(IlOps.CALL, netOperator.token, 2, 1);
		} else if (string) {
			var eq = g.mb.memberRef(g.typeTokenOf(LString), "op_Equality", g.sigs.method(false, LBool, [LString, LString], 0));
			code.opToken(IlOps.CALL, eq, 2, 1);
			if (op.match(OpNotEq)) not();
		} else {
			switch (op) {
				case OpEq:
					code.op(IlOps.CEQ, 2, 1);
				case OpNotEq:
					code.op(IlOps.CEQ, 2, 1);
					not();
				case OpLt:
					code.op(unsigned ? IlOps.CLT_UN : IlOps.CLT, 2, 1);
				case OpGt:
					code.op(unsigned ? IlOps.CGT_UN : IlOps.CGT, 2, 1);
				case OpLte:
					// An unordered comparison is true on NaN, so inverting it makes <= false there.
					code.op(isFloat || unsigned ? IlOps.CGT_UN : IlOps.CGT, 2, 1);
					not();
				case _:
					code.op(isFloat || unsigned ? IlOps.CLT_UN : IlOps.CLT, 2, 1);
					not();
			}
		}
		tl.coerce(LBool, ret);
	}

	// The .NET class whose operators C# looks up for a value of type `t`: its own, or for a Haxe class
	// its nearest .NET superclass's.
	function netClassOf(t:T):Null<TClass> {
		var c = switch (TypeFunctions.follow(t)) {
			case TInst(c, _): c;
			case _: null;
		}
		while (c != null && !isExtern(c)) c = c.superClass == null ? null : c.superClass.c;
		return c;
	}

	// The op_Equality or op_Inequality C# binds `==` or `!=` on two references to, or null when neither
	// operand's .NET class declares one and the comparison is of references.
	function equalityOperator(op:Binop, e1:TExpr, e2:TExpr):Null<{token:Int, args:Array<IlSigNorm>}> {
		var name = op.match(OpEq) ? "op_Equality" : "op_Inequality";
		var candidates = [];
		for (e in [e1, e2]) {
			if (isNullConst(e)) continue;
			var c = netClassOf(e.type);
			if (c == null || isStringClass(c)) continue;
			for (o in g.externs.operators(c, name)) {
				var seen = false;
				for (k in candidates) if (IlPaths.sigEq(k.parent, o.parent) && IlPaths.sigsEq(k.args, o.args)) seen = true;
				if (!seen) candidates.push(o);
			}
		}
		if (candidates.length == 0) return null;
		function accepts(param:IlSigNorm, e:TExpr):Bool {
			if (isNullConst(e)) return isReference(param);
			var s = tl.sig(e.type);
			return IlPaths.sigEq(s, param) || g.isUpcast(s, param);
		}
		var applicable = [for (o in candidates) if (o.args.length == 2 && accepts(o.args[0], e1) && accepts(o.args[1], e2)) o];
		// C# would pick the best of several by its overload rules, which are not ported.
		if (applicable.length != 1) throw new Unsupported("the " + Ast.sBinop(op) + " operator on these .NET types", false);
		var o = applicable[0];
		var ret = switch (o.sig) {
			case LMethod(_, r, _): r;
			case _: throw "internal error: not a method signature";
		}
		if (!ret.match(LBool)) throw new Unsupported("the " + Ast.sBinop(op) + " operator on these .NET types", false);
		return {token: g.mb.memberRef(g.typeTokenOf(o.parent), name, g.sigs.methodSig(o.sig, 0)), args: o.args};
	}

	// Jumps to `l` when the condition equals `sense`, else falls through.
	function jumpIf(e:TExpr, l:Label, sense:Bool):Void {
		if (!code.reachable()) return;
		switch (e.expr) {
			case TParenthesis(e1) | TMeta(_, e1):
				jumpIf(e1, l, sense);
			case TUnop(Not, _, e1):
				jumpIf(e1, l, !sense);
			case TBinop(OpBoolAnd, a, b) | TBinop(OpBoolOr, a, b):
				// `a && b` jumps on false when either is false; it jumps on true only when both are true.
				var isAnd = e.expr.match(TBinop(OpBoolAnd, _, _));
				if (isAnd != sense) {
					jumpIf(a, l, sense);
					jumpIf(b, l, sense);
				} else {
					var skip = code.newLabel();
					jumpIf(a, skip, !sense);
					jumpIf(b, l, sense);
					code.markIfUsed(skip);
				}
			case TConst(TBool(b)):
				if (b == sense) code.branch(IlOps.BR, l);
			case _:
				// A Dynamic converts through Runtime.toBool, as gencs casts a condition to Bool.
				tl.texpr(RValue(LBool), e);
				code.branch(sense ? IlOps.BRTRUE : IlOps.BRFALSE, l);
		}
	}

	// `&&` and `||` as a value.
	function boolValue(ret:Ret, e:TExpr):Void {
		var f = code.newLabel(), end = code.newLabel();
		jumpIf(e, f, false);
		if (code.reachable()) {
			code.ldcI4(1);
			code.branch(IlOps.BR, end);
		}
		if (code.targeted(f)) {
			code.mark(f);
			code.ldcI4(0);
		}
		code.markIfUsed(end);
		tl.coerce(LBool, ret);
	}

	function unary(ret:Ret, e:TExpr, op:Unop, flag:UnopFlag, e1:TExpr):Void {
		if (op.match(Neg | NegBits) && tl.dyn.unary(ret, e, op, e1)) return;
		switch (op) {
			case Not:
				tl.texpr(RValue(LBool), e1);
				not();
				tl.coerce(LBool, ret);
			case Neg:
				var own = tl.sig(e.type);
				var t = tl.unNull(own);
				if (!isNumeric(t)) throw new Unsupported("the - operator on these types", false);
				tl.texpr(RValue(t), e1);
				code.op(IlOps.NEG, 1, 1);
				tl.dyn.finish(t, own, ret);
			case NegBits:
				var own = tl.sig(e.type);
				var t = tl.unNull(own);
				if (!t.match(LInt32)) throw new Unsupported("the ~ operator on these types", false);
				tl.texpr(RValue(t), e1);
				code.op(IlOps.NOT, 1, 1);
				tl.dyn.finish(t, own, ret);
			case Increment | Decrement:
				incDec(ret, e, op.match(Increment), flag.match(Postfix), e1);
			case Spread:
				throw new Unsupported("the spread operator", false);
		}
	}

	function incDec(ret:Ret, e:TExpr, increment:Bool, postfix:Bool, e1:TExpr):Void {
		if (tl.dyn.incDec(ret, e, increment, postfix, e1)) return;
		var p = tl.place(e1);
		if (p == null) throw new Unsupported("this kind of assignment", false);
		if (!isNumeric(p.sig)) throw new Unsupported("the " + (increment ? "++" : "--") + " operator on these types", false);
		function step() {
			if (isIntLike(p.sig)) code.ldcI4(1) else code.opR8(IlOps.LDC_R8, 1.0, 0, 1);
			code.op(increment ? IlOps.ADD : IlOps.SUB, 2, 1);
		}
		p.prepare();
		p.load();
		if (!needVal(ret)) {
			step();
			p.store();
			return;
		}
		var tmp = -1;
		if (postfix) {
			tmp = keep(p);
			step();
			p.store();
		} else {
			step();
			tmp = keep(p);
			p.store();
		}
		if (tmp >= 0) code.ldloc(tmp);
		tl.coerce(p.sig, ret);
	}

	// Copies the value on top for after the place's store: it stays under the value, or goes to a temp
	// when the receiver is under it.
	function keep(p:Place):Int {
		if (!p.receiver) {
			code.op(IlOps.DUP, 1, 2);
			return -1;
		}
		return keepTop(p.sig);
	}

	function keepTop(s:IlSigNorm):Int {
		code.op(IlOps.DUP, 1, 2);
		var tmp = code.addLocal(s);
		code.stloc(tmp);
		return tmp;
	}

	function compound(ret:Ret, e:TExpr, op:Binop, lhs:TExpr, rhs:TExpr):Void {
		if (tl.dyn.compound(ret, e, op, lhs, rhs)) return;
		var p = tl.place(lhs);
		if (p == null) throw new Unsupported("this kind of assignment", false);
		p.prepare();
		p.load();
		if (op.match(OpAdd) && p.sig.match(LString)) {
			stringifyTop(LString);
			pushString(rhs);
			concat();
		} else {
			numericTail(op, p.sig, rhs, p.sig, false);
		}
		var tmp = needVal(ret) ? keep(p) : -1;
		p.store();
		if (needVal(ret)) {
			if (tmp >= 0) code.ldloc(tmp);
			tl.coerce(p.sig, ret);
		}
	}

	// `+` on Strings: String.Concat over operands that cannot be null.
	function concat():Void {
		var token = g.mb.memberRef(g.typeTokenOf(LString), "Concat", g.sigs.method(false, LString, [LString, LString], 0));
		code.opToken(IlOps.CALL, token, 2, 1);
	}

	// Pushes the operand of a String concatenation as a String; null becomes "null", as Runtime.toString
	// writes it.
	function pushString(e:TExpr):Void {
		var inner = strip(e);
		switch (inner.expr) {
			case TConst(TString(_)):
				tl.texpr(RValue(LString), inner);
				return;
			case TConst(TNull):
				code.opToken(IlOps.LDSTR, g.mb.userString("null"), 0, 1);
				return;
			case TBinop(OpAdd, _, _) if (tl.sig(inner.type).match(LString)):
				// A concatenation is never null.
				tl.texpr(RValue(LString), inner);
				return;
			case _:
		}
		var s = tl.sig(e.type);
		if (tl.isHaxeNull(s)) {
			// A Null<T> through toDynamic(), so an empty one prints null.
			tl.nullOperand(RValue(LObject), e);
			tl.dyn.stdString();
			return;
		}
		stringKind(s);
		tl.texpr(RValue(s), e);
		stringifyTop(s);
	}

	// Throws for the types a String conversion does not handle yet.
	static function stringKind(s:IlSigNorm):Void {
		switch (s) {
			case LObject | LTypeParam(_) | LMethodTypeParam(_):
			case LString | LBool | LClass(_, _) | LVector(_) | LArray(_, _):
			case _ if (DotnetTypes.isValueType(s)):
			case _:
				throw new Unsupported("this type in string concatenation", false);
		}
	}

	// The value of type `s` on the stack becomes a String.
	function stringifyTop(s:IlSigNorm):Void {
		stringKind(s);
		function nullText() code.opToken(IlOps.LDSTR, g.mb.userString("null"), 0, 1);
		switch (s) {
			case LObject:
				// Std.string, as gencs writes a Dynamic in a concatenation.
				tl.dyn.stdString();
			case LTypeParam(_) | LMethodTypeParam(_):
				code.opToken(IlOps.BOX, g.typeTokenOf(s), 1, 1);
				tl.dyn.stdString();
			case LString:
				var notNull = code.newLabel();
				code.op(IlOps.DUP, 1, 2);
				code.branch(IlOps.BRTRUE, notNull);
				code.op(IlOps.POP, 1, 0);
				nullText();
				code.mark(notNull);
			case LBool:
				var isTrue = code.newLabel(), end = code.newLabel();
				code.branch(IlOps.BRTRUE, isTrue);
				code.opToken(IlOps.LDSTR, g.mb.userString("false"), 0, 1);
				code.branch(IlOps.BR, end);
				code.mark(isTrue);
				code.opToken(IlOps.LDSTR, g.mb.userString("true"), 0, 1);
				code.mark(end);
			case _ if (DotnetTypes.isValueType(s)):
				code.opToken(IlOps.BOX, g.typeTokenOf(s), 1, 1);
				objectToString();
			case _:
				var notNull = code.newLabel(), end = code.newLabel();
				code.op(IlOps.DUP, 1, 2);
				code.branch(IlOps.BRTRUE, notNull);
				code.op(IlOps.POP, 1, 0);
				nullText();
				code.branch(IlOps.BR, end);
				code.mark(notNull);
				objectToString();
				code.mark(end);
		}
	}

	function objectToString():Void {
		var token = g.mb.memberRef(g.typeTokenOf(LObject), "ToString", g.sigs.method(true, LString, [], 0));
		code.opToken(IlOps.CALLVIRT, token, 1, 1);
	}
}
