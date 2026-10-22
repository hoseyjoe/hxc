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

// Where an expression's value goes: onto the stack as a slot of the given type (null: its own),
// nowhere, or out of the function (a function body, whose value is not used).
enum Ret {
	RValue(t:Null<IlSigNorm>);
	RVoid;
	RReturn;
}

// A local or argument slot.
private typedef Slot = {arg:Bool, index:Int, sig:IlSigNorm};

// One method body's expressions as IL. Anything outside the subset this milestone compiles throws
// Unsupported naming it.

class TexprToIl {
	final g:DotnetCtx;
	final code:IlCode;
	final ret:IlSigNorm;
	final slots = new Map<Int, Slot>();
	// Variables whose declaration failed to lower; a failing statement that uses one is not reported
	// again.
	final poisoned = new Map<Int, Bool>();

	// Set for user code: a statement that fails to lower is reported here and lowering goes on with
	// the next one. Unset, the Unsupported propagates.
	public var onError:Null<Unsupported->Void> = null;

	public function new(g:DotnetCtx, code:IlCode, ret:IlSigNorm) {
		this.g = g;
		this.code = code;
		this.ret = ret;
	}

	public function bindArg(v:TVar, index:Int, sig:IlSigNorm):Void {
		slots.set(v.id, {arg: true, index: index, sig: sig});
	}

	public function texpr(ret:Ret, e:TExpr):Void {
		if (!code.reachable()) return;
		try {
			expr(ret, e);
		} catch (u:Unsupported) {
			if (u.pos == null) u.pos = e.pos;
			throw u;
		}
	}

	// The end of the body: a void method returns.
	public function finish():Void {
		if (!code.reachable()) return;
		if (!ret.match(LVoid)) throw "internal error: a non-void method falls off its end";
		code.op(IlOps.RET, 0, 0);
	}

	static inline function needVal(ret:Ret):Bool return ret.match(RValue(_));

	inline function sig(t:T):IlSigNorm return g.types.toSig(t);

	static function isTypeParam(s:IlSigNorm):Bool return s.match(LTypeParam(_) | LMethodTypeParam(_));

	// Moves a value of type `from` (null: the null reference, LVoid: nothing) to where `ret` wants it.
	function coerce(from:Null<IlSigNorm>, ret:Ret):Void {
		switch (ret) {
			case RVoid | RReturn:
				if (from == null || !from.match(LVoid)) code.op(IlOps.POP, 1, 0);
			case RValue(null):
				if (from != null && from.match(LVoid)) throw new Unsupported("Void values", true);
			case RValue(to):
				if (from != null && from.match(LVoid)) throw new Unsupported("Void values", true);
				convert(from, to);
		}
	}

	function convert(from:Null<IlSigNorm>, to:IlSigNorm):Void {
		if (from == null) {
			if (DotnetTypes.isValueType(to)) throw new Unsupported("null as a value type", false);
			return;
		}
		if (IlPaths.sigEq(from, to)) return;
		var fromValue = DotnetTypes.isValueType(from) || isTypeParam(from);
		var toValue = DotnetTypes.isValueType(to) || isTypeParam(to);
		if (fromValue && !toValue) {
			code.opToken(IlOps.BOX, g.typeTokenOf(from), 1, 1);
		} else if (!fromValue && toValue) {
			code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
		} else if (fromValue) {
			if (from.match(LInt32) && to.match(LFloat64)) code.op(IlOps.CONV_R8, 1, 1);
			else throw new Unsupported("conversions between value types", true);
		} else if (from.match(LObject)) {
			code.opToken(IlOps.CASTCLASS, g.typeTokenOf(to), 1, 1);
		}
	}

	function slot(v:TVar):Slot {
		var s = slots.get(v.id);
		if (s == null) throw "internal error: unbound variable " + v.name;
		return s;
	}

	function load(s:Slot):Void {
		if (s.arg) code.ldarg(s.index) else code.ldloc(s.index);
	}

	function store(s:Slot):Void {
		if (s.arg) code.starg(s.index) else code.stloc(s.index);
	}

	function expr(ret:Ret, e:TExpr):Void {
		switch (e.expr) {
			case TConst(TInt(_) | TFloat(_) | TString(_) | TBool(_) | TNull) | TLocal(_) if (!needVal(ret)):
			case TConst(TInt(v)):
				code.ldcI4(v);
				coerce(LInt32, ret);
			case TConst(TFloat(s)):
				code.opR8(IlOps.LDC_R8, Std.parseFloat(s), 0, 1);
				coerce(LFloat64, ret);
			case TConst(TString(s)):
				code.opToken(IlOps.LDSTR, g.mb.userString(s), 0, 1);
				coerce(LString, ret);
			case TConst(TBool(b)):
				code.ldcI4(b ? 1 : 0);
				coerce(LBool, ret);
			case TConst(TNull):
				code.op(IlOps.LDNULL, 0, 1);
				coerce(null, ret);
			case TConst(TThis):
				throw new Unsupported("`this`", false);
			case TConst(TSuper):
				throw new Unsupported("`super`", false);
			case TLocal(v):
				var s = slot(v);
				load(s);
				coerce(s.sig, ret);
			case TVarExpr(v, init):
				// A variable of a type not supported yet is reported after what its initializer uses.
				var s = try sig(v.type) catch (u:Unsupported) {
					if (init != null) texpr(RValue(null), init);
					throw u;
				}
				var local = {arg: false, index: code.addLocal(s), sig: s};
				if (init != null) {
					texpr(RValue(s), init);
					store(local);
				}
				slots.set(v.id, local);
				coerce(LVoid, ret);
			case TBlock(el):
				block(ret, el);
			case TReturn(null):
				code.op(IlOps.RET, 0, 0);
			case TReturn(e1):
				texpr(RValue(this.ret), e1);
				code.op(IlOps.RET, 1, 0);
			case TParenthesis(e1) | TMeta(_, e1):
				texpr(ret, e1);
			case TCast(e1, null):
				texpr(switch (ret) {
					case RValue(null): RValue(sig(e.type));
					case r: r;
				}, e1);
			case TBinop(OpAssign, lhs, rhs):
				assign(ret, lhs, rhs);
			case TBinop(op = OpAdd | OpSub | OpMult | OpDiv, e1, e2):
				arith(ret, e, op, e1, e2);
			case TField(obj, fa):
				fieldRead(ret, e, obj, fa);
			case TCall(callee, args):
				call(ret, e, callee, args);
			case TNew(c, params, args):
				construct(ret, c, params, args);
			case TFunction(_):
				throw new Unsupported("local functions", true);
			case TTypeExpr(_):
				throw new Unsupported("type expressions", true);
			case TArray(_, _):
				throw new Unsupported("array access", false);
			case TBinop(op, _, _):
				throw new Unsupported("the " + Ast.sBinop(op) + " operator", false);
			case TObjectDecl(_):
				throw new Unsupported("anonymous objects", true);
			case TArrayDecl(_):
				throw new Unsupported("array literals", true);
			case TUnop(op, _, _):
				throw new Unsupported("the " + Ast.sUnop(op) + " operator", false);
			case TFor(_, _, _):
				throw new Unsupported("for loops", true);
			case TIf(_, _, _):
				throw new Unsupported("if expressions", true);
			case TWhile(_, _, _):
				throw new Unsupported("while loops", true);
			case TSwitch(_, _, _):
				throw new Unsupported("switch expressions", true);
			case TTry(_, _):
				throw new Unsupported("try/catch", false);
			case TBreak:
				throw new Unsupported("`break`", false);
			case TContinue:
				throw new Unsupported("`continue`", false);
			case TThrow(_):
				throw new Unsupported("`throw`", false);
			case TCast(_, _):
				throw new Unsupported("checked casts", true);
			case TEnumParameter(_, _, _) | TEnumIndex(_):
				throw new Unsupported("enum values", true);
			case TIdent(_):
				throw new Unsupported("untyped code", false);
		}
	}

	// Statements, then the last expression where `ret` wants it. In user code a failing statement is
	// reported and the next one lowered.
	function block(ret:Ret, el:Array<TExpr>):Void {
		if (el.length == 0) {
			coerce(LVoid, ret);
			return;
		}
		for (i in 0...el.length) {
			var s = el[i];
			var r = i == el.length - 1 ? (ret.match(RReturn) ? RVoid : ret) : RVoid;
			if (onError == null) {
				texpr(r, s);
				continue;
			}
			var depth = code.depth;
			try {
				texpr(r, s);
			} catch (u:Unsupported) {
				code.resetDepth(depth);
				var usesPoisoned = TexprTools.checkExpr(function(e) return switch (e.expr) {
					case TLocal(v): poisoned.exists(v.id);
					case _: false;
				}, s);
				switch (s.expr) {
					case TVarExpr(v, _): poisoned.set(v.id, true);
					case _:
				}
				if (!usesPoisoned) onError(u);
			}
		}
	}

	function staticField(c:TClass, cf:TClassField):{token:Int, sig:IlSigNorm} {
		g.types.checkKept(TClassDecl(c));
		if (c.params.length > 0) throw new Unsupported("static members of generic classes", true);
		var token = g.fieldTokens.get(cf);
		if (token == null) throw "internal error: no field " + Globals.sTypePath(c.path) + "." + cf.name;
		return {token: token, sig: g.fieldSigs.get(cf)};
	}

	static function isExtern(c:TClass):Bool return TypeFunctions.hasClassFlag(c, CExtern);

	function assign(ret:Ret, lhs:TExpr, rhs:TExpr):Void {
		switch (lhs.expr) {
			case TLocal(v):
				var s = slot(v);
				texpr(RValue(s.sig), rhs);
				if (needVal(ret)) code.op(IlOps.DUP, 1, 2);
				store(s);
				if (needVal(ret)) coerce(s.sig, ret);
			case TField(_, FStatic(c, cf)) if (!isExtern(c)):
				var f = staticField(c, cf);
				texpr(RValue(f.sig), rhs);
				if (needVal(ret)) code.op(IlOps.DUP, 1, 2);
				code.opToken(IlOps.STSFLD, f.token, 1, 0);
				if (needVal(ret)) coerce(f.sig, ret);
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c)):
				var isStatic = fa.match(FStatic(_, _));
				var inst = instantiation(c, fa);
				var parent = parentOf(c, inst);
				switch (g.externs.field(c, cf)) {
					case XField(open):
						var s = ExternMembers.subst(open, inst);
						if (needVal(ret)) throw new Unsupported("the value of an assignment to a .NET field", false);
						if (!isStatic) receiver(obj, parent);
						texpr(RValue(s), rhs);
						var token = g.mb.memberRef(g.typeTokenOf(parent), cf.name, g.sigs.field(open));
						code.opToken(isStatic ? IlOps.STSFLD : IlOps.STFLD, token, isStatic ? 1 : 2, 0);
					case XProperty(open, _, setter) if (setter != null):
						var s = ExternMembers.subst(open, inst);
						if (needVal(ret)) throw new Unsupported("the value of an assignment to a .NET property", false);
						if (!isStatic) receiver(obj, parent);
						texpr(RValue(s), rhs);
						var token = g.mb.memberRef(g.typeTokenOf(parent), setter, g.sigs.method(!isStatic, LVoid, [open], 0));
						code.opToken(isStatic || parent.match(LValueType(_, _)) ? IlOps.CALL : IlOps.CALLVIRT, token, isStatic ? 1 : 2, 0);
					case _:
						throw new Unsupported("assignments to a read-only .NET member", true);
				}
			case _:
				throw new Unsupported("this kind of assignment", false);
		}
	}

	function arith(ret:Ret, e:TExpr, op:Binop, e1:TExpr, e2:TExpr):Void {
		var t = sig(e.type);
		var opcode = switch (op) {
			case OpAdd: IlOps.ADD;
			case OpSub: IlOps.SUB;
			case OpMult: IlOps.MUL;
			case _: IlOps.DIV;
		}
		inline function numeric(s:IlSigNorm) return s.match(LInt32 | LFloat64);
		if (t.match(LString)) throw new Unsupported("string concatenation", false);
		if (!numeric(t) || !numeric(sig(e1.type)) || !numeric(sig(e2.type)) || (op.match(OpDiv) && !t.match(LFloat64)))
			throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
		texpr(RValue(t), e1);
		texpr(RValue(t), e2);
		code.op(opcode, 2, 1);
		coerce(t, ret);
	}

	// The class type arguments a field access sees: a static one gets Dynamic for each.
	function instantiation(c:TClass, fa:TFieldAccess):Array<IlSigNorm> {
		return switch (fa) {
			case FInstance(_, params, _): [for (p in params) sig(p)];
			case _: [for (_ in c.params) LObject];
		}
	}

	function parentOf(c:TClass, inst:Array<IlSigNorm>):IlSigNorm {
		return switch (sig(TInst(c, [for (_ in c.params) TypeFunctions.tDynamic]))) {
			case LClass(p, _): LClass(p, inst);
			case LValueType(p, _): LValueType(p, inst);
			case s: s;
		}
	}

	// The object an instance member is reached through; a value type's address.
	function receiver(obj:TExpr, parent:IlSigNorm):Void {
		if (!parent.match(LValueType(_, _))) {
			texpr(RValue(parent), obj);
			return;
		}
		switch (obj.expr) {
			case TLocal(v):
				var s = slot(v);
				if (s.arg) code.ldarga(s.index) else code.ldloca(s.index);
			case _:
				texpr(RValue(parent), obj);
				var tmp = code.addLocal(parent);
				code.stloc(tmp);
				code.ldloca(tmp);
		}
	}

	function constant(c:IlConstant):Null<IlSigNorm> {
		switch (c) {
			case IBool(b):
				code.ldcI4(b ? 1 : 0);
				return LBool;
			case IChar(i):
				code.ldcI4(i);
				return LChar;
			case IByte(i):
				code.ldcI4(i);
				return LUInt8;
			case IShort(i):
				code.ldcI4(i);
				return LInt16;
			case IInt(i):
				code.ldcI4(i);
				return LInt32;
			case IInt64(i):
				code.opI64(IlOps.LDC_I8, i, 0, 1);
				return LInt64;
			case IFloat32(f):
				code.opR4(IlOps.LDC_R4, f, 0, 1);
				return LFloat32;
			case IFloat64(f):
				code.opR8(IlOps.LDC_R8, f, 0, 1);
				return LFloat64;
			case IString(b):
				var buf = new StringBuf();
				var i = 0;
				while (i + 1 < b.length) {
					var u = b.getUInt16(i);
					i += 2;
					if (u >= 0xD800 && u < 0xDC00 && i + 1 < b.length) {
						var lo = b.getUInt16(i);
						i += 2;
						u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
					}
					buf.addChar(u);
				}
				code.opToken(IlOps.LDSTR, g.mb.userString(buf.toString()), 0, 1);
				return LString;
			case INull:
				code.op(IlOps.LDNULL, 0, 1);
				return null;
		}
	}

	function fieldRead(ret:Ret, e:TExpr, obj:TExpr, fa:TFieldAccess):Void {
		switch (fa) {
			case FStatic(c, cf) if (!isExtern(c)):
				if (!cf.kind.match(Var(_))) throw new Unsupported("method closures", true);
				var f = staticField(c, cf);
				if (!needVal(ret)) return;
				code.opToken(IlOps.LDSFLD, f.token, 0, 1);
				coerce(f.sig, ret);
			case FStatic(c, cf) | FInstance(c, _, cf) if (isExtern(c)):
				if (!cf.kind.match(Var(_))) throw new Unsupported("method closures", true);
				var isStatic = fa.match(FStatic(_, _));
				var inst = instantiation(c, fa);
				var parent = parentOf(c, inst);
				switch (g.externs.field(c, cf)) {
					case XConstant(k):
						if (!isStatic) throw new Unsupported("instance .NET constants", true);
						var s = constant(k);
						coerce(s, ret);
					case XField(open):
						if (!isStatic) receiver(obj, parent);
						var token = g.mb.memberRef(g.typeTokenOf(parent), cf.name, g.sigs.field(open));
						code.opToken(isStatic ? IlOps.LDSFLD : IlOps.LDFLD, token, isStatic ? 0 : 1, 1);
						coerce(ExternMembers.subst(open, inst), ret);
					case XProperty(open, getter, _) if (getter != null):
						if (!isStatic) receiver(obj, parent);
						var token = g.mb.memberRef(g.typeTokenOf(parent), getter, g.sigs.method(!isStatic, open, [], 0));
						code.opToken(isStatic || parent.match(LValueType(_, _)) ? IlOps.CALL : IlOps.CALLVIRT, token, isStatic ? 0 : 1, 1);
						coerce(ExternMembers.subst(open, inst), ret);
					case _:
						throw new Unsupported("reading a write-only .NET property", false);
				}
			case FInstance(_, _, _):
				throw new Unsupported("instance fields of Haxe classes", true);
			case FStatic(_, _):
				throw new Unsupported("this kind of field access", false);
			case FAnon(_):
				throw new Unsupported("anonymous structure fields", true);
			case FDynamic(_):
				throw new Unsupported("dynamic field access", false);
			case FClosure(_, _):
				throw new Unsupported("method closures", true);
			case FEnum(_, _):
				throw new Unsupported("enum constructors", true);
		}
	}

	function pushArgs(args:Array<TExpr>, slots:Array<IlSigNorm>):Void {
		if (args.length != slots.length) throw new Unsupported("calls that leave out arguments", true);
		for (i in 0...args.length) texpr(RValue(slots[i]), args[i]);
	}

	function call(ret:Ret, e:TExpr, callee:TExpr, args:Array<TExpr>):Void {
		switch (callee.expr) {
			case TField(_, FStatic(c, cf)) if (!isExtern(c)):
				g.types.checkKept(TClassDecl(c));
				if (c.params.length > 0) throw new Unsupported("static members of generic classes", true);
				if (cf.params.length > 0) throw new Unsupported("calls to generic methods", true);
				var token = g.methodTokens.get(cf);
				if (token == null) throw "internal error: no method " + Globals.sTypePath(c.path) + "." + cf.name;
				var m = g.methodSigs.get(cf);
				pushArgs(args, m.args);
				code.opToken(IlOps.CALL, token, args.length, m.ret.match(LVoid) ? 0 : 1);
				coerce(m.ret, ret);
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c)):
				var isStatic = fa.match(FStatic(_, _));
				var m = g.externs.method(c, cf);
				if (m.genericCount > 0) throw new Unsupported("generic .NET methods", true);
				var inst = instantiation(c, fa);
				var parent = ExternMembers.subst(m.parent, inst);
				var parentArgs = switch (parent) {
					case LClass(_, l) | LValueType(_, l): l;
					case _: [];
				}
				var ilRet:IlSigNorm, ilArgs:Array<IlSigNorm>;
				switch (m.sig) {
					case LMethod(_, r, l):
						ilRet = r;
						ilArgs = l;
					case _:
						throw "internal error: not a method signature";
				}
				if (!isStatic) receiver(obj, parent);
				pushArgs(args, [for (a in ilArgs) ExternMembers.subst(a, parentArgs)]);
				var token = g.mb.memberRef(g.typeTokenOf(parent), m.name, g.sigs.methodSig(m.sig, 0));
				var retSlot = ExternMembers.subst(ilRet, parentArgs);
				var op = isStatic || parent.match(LValueType(_, _)) ? IlOps.CALL : IlOps.CALLVIRT;
				code.opToken(op, token, args.length + (isStatic ? 0 : 1), retSlot.match(LVoid) ? 0 : 1);
				if (retSlot.match(LVoid) && needVal(ret)) throw new Unsupported("the value of a .NET setter call", false);
				coerce(retSlot, ret);
			case TConst(TSuper):
				throw new Unsupported("`super` calls", true);
			case TField(_, FInstance(_, _, _)):
				throw new Unsupported("instance methods of Haxe classes", true);
			case TIdent(_):
				throw new Unsupported("untyped code", false);
			case _:
				throw new Unsupported("calls of function values", true);
		}
	}

	function construct(ret:Ret, c:TClass, params:TParams, args:Array<TExpr>):Void {
		if (!isExtern(c)) throw new Unsupported("instances of Haxe classes", true);
		var r = OverloadResolution.maybeResolveConstructorOverload(c, params, args);
		if (r == null) throw "internal error: no constructor of " + Globals.sTypePath(c.path) + " fits";
		if (r.c != c) throw new Unsupported("inherited .NET constructors", true);
		var m = g.externs.method(c, r.cf);
		var parent = ExternMembers.subst(m.parent, [for (p in params) sig(p)]);
		var parentArgs = switch (parent) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
		var ilArgs = switch (m.sig) {
			case LMethod(_, _, l): l;
			case _: throw "internal error: not a method signature";
		}
		pushArgs(args, [for (a in ilArgs) ExternMembers.subst(a, parentArgs)]);
		var token = g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.methodSig(m.sig, 0));
		code.opToken(IlOps.NEWOBJ, token, args.length, 1);
		coerce(parent, ret);
	}
}
