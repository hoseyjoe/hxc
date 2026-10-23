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

// Where an expression's value goes: onto the stack as a slot of the given type (null: its own),
// nowhere, or out of the function (a function body, whose value is not used).
enum Ret {
	RValue(t:Null<IlSigNorm>);
	RVoid;
	RReturn;
}

// A local or argument slot.
private typedef Slot = {arg:Bool, index:Int, sig:IlSigNorm};

// Something that can be loaded and stored. `prepare` pushes the receiver, if there is one; `load` keeps
// it under the value and `store` takes both.
private typedef Place = {sig:IlSigNorm, receiver:Bool, prepare:Void->Void, load:Void->Void, store:Void->Void};

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
	// Where break and continue go, innermost loop last.
	final loops:Array<{brk:Label, cont:Label}> = [];

	// Set for user code: a statement that fails to lower is reported here and lowering goes on with
	// the next one. Unset, the Unsupported propagates.
	public var onError:Null<Unsupported->Void> = null;

	// The class whose method this is, and its own type as `this` has it (null in a static method).
	public var cls:Null<TClass> = null;
	public var thisSig:Null<IlSigNorm> = null;

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
			// null as a type parameter is C#'s default(T).
			if (isTypeParam(to)) {
				code.op(IlOps.POP, 1, 0);
				defaultValue(to);
				return;
			}
			if (isHaxeNull(to)) throw new Unsupported("Null<T> of a value type", false);
			if (DotnetTypes.isValueType(to)) throw new Unsupported("null as a value type", false);
			return;
		}
		if (IlPaths.sigEq(from, to)) return;
		// haxe.lang.Null<T> converts through its constructor and fields, which milestone 2 does not use.
		if (isHaxeNull(from) || isHaxeNull(to)) throw new Unsupported("Null<T> of a value type", false);
		// Int and UInt are both an int32 on the stack.
		if (isIntLike(from) && isIntLike(to)) return;
		var fromValue = DotnetTypes.isValueType(from) || isTypeParam(from);
		var toValue = DotnetTypes.isValueType(to) || isTypeParam(to);
		if (fromValue && !toValue) {
			// A struct boxes into an instantiation of a generic Haxe interface only when it implements it.
			if (!isTypeParam(from) && g.isGenericHaxeClass(to) && !g.isUpcast(from, to)) throw instantiationCast(to);
			code.opToken(IlOps.BOX, g.typeTokenOf(from), 1, 1);
			// A boxed type parameter is an object, which may not be the reference type wanted.
			if (isTypeParam(from) && !to.match(LObject)) castTo(to);
		} else if (!fromValue && toValue) {
			// gencs converts Dynamic to a primitive through Runtime.toBool, toInt and toDouble, which accept
			// null and boxed numbers of another type; an unbox.any would throw on them.
			if (from.match(LObject) && isPrimitive(to)) throw new Unsupported("Dynamic to Bool/Int/Float conversions", true);
			code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
		} else if (fromValue) {
			if (from.match(LInt32) && to.match(LFloat64)) code.op(IlOps.CONV_R8, 1, 1);
			else if (from.match(LUInt32) && to.match(LFloat64)) {
				code.op(IlOps.CONV_R_UN, 1, 1);
				code.op(IlOps.CONV_R8, 1, 1);
			} else if (from.match(LFloat64) && to.match(LInt32)) code.op(IlOps.CONV_I4, 1, 1);
			else if (isTypeParam(from) || isTypeParam(to)) {
				// Between a type parameter and another type that is one at run time, as C# casts through object.
				code.opToken(IlOps.BOX, g.typeTokenOf(from), 1, 1);
				code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
			} else throw new Unsupported("conversions between value types", true);
		} else if (isReference(from) && isReference(to) && !to.match(LObject)) {
			// An upcast needs nothing; anything else may narrow.
			if (g.isUpcast(from, to) || from.match(LVector(_)) && isSystemArray(to)) return;
			castTo(to);
		}
	}

	static function isSystemArray(s:IlSigNorm):Bool {
		return switch (s) {
			case LClass(p, []): p.ns.length == 1 && p.ns[0] == "System" && p.nested.length == 0 && p.name == "Array";
			case _: false;
		}
	}

	static function isIntLike(s:IlSigNorm):Bool return s.match(LInt32 | LUInt32);

	// gencs's haxe.lang.Null<T>, which Null<T> of a value type maps to.
	function isHaxeNull(s:IlSigNorm):Bool {
		return s.match(LValueType(_, [_])) && g.haxePathOf(s) == "cs.internal._Null.Nullable";
	}


	// C#'s default(T): a zeroed temporary.
	function defaultValue(t:IlSigNorm):Void {
		var tmp = code.addLocal(t);
		code.ldloca(tmp);
		code.opToken(IlOps.INITOBJ, g.typeTokenOf(t), 1, 0);
		code.ldloc(tmp);
	}

	// gencs gives a generic Haxe class real type arguments and converts between instantiations with
	// __hx_cast, which copies (Haxe issue 8314); castclass would throw where it converts. Milestone 3
	// lowers these casts as the spec's "Casts between generic instantiations" says.
	function instantiationCast(to:IlSigNorm):Unsupported {
		return new Unsupported("a cast between instantiations of " + g.haxePathOf(to), false);
	}

	// Throws for a cast from `from` into an instantiation of a generic Haxe class that is not the same
	// type or an upcast.
	function checkInstantiationCast(from:IlSigNorm, to:IlSigNorm):Void {
		if (IlPaths.sigEq(from, to) || !g.isGenericHaxeClass(to)) return;
		if (g.isUpcast(from, to)) return;
		throw instantiationCast(to);
	}

	function castTo(to:IlSigNorm):Void {
		if (g.isGenericHaxeClass(to)) throw instantiationCast(to);
		code.opToken(IlOps.CASTCLASS, g.typeTokenOf(to), 1, 1);
	}

	static function isPrimitive(s:IlSigNorm):Bool {
		return s.match(LBool | LChar | LInt8 | LUInt8 | LInt16 | LUInt16 | LInt32 | LUInt32 | LInt64 | LUInt64 | LFloat32 | LFloat64);
	}

	static function isReference(s:IlSigNorm):Bool return s.match(LObject | LString | LClass(_, _) | LVector(_) | LArray(_, _));

	function slot(v:TVar):Slot {
		var s = slots.get(v.id);
		// The statement using it is not reported again: the declaration already was.
		if (s == null && poisoned.exists(v.id)) throw new Unsupported("a variable whose declaration failed", false);
		if (s == null) throw "internal error: unbound variable " + v.name;
		if (s.sig.match(LManagedPointer(_))) throw new Unsupported("cs.Ref and cs.Out parameters", true);
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
				if (thisSig == null) throw new Unsupported("`this`", false);
				code.ldarg(0);
				// A struct's `this` is its address.
				if (DotnetTypes.isValueType(thisSig)) code.opToken(IlOps.LDOBJ, g.typeTokenOf(thisSig), 1, 1);
				coerce(thisSig, ret);
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
				// A branch out of an expression would leave its operands on the stack.
				if (code.depth != 0) throw new Unsupported("`return` inside expressions", false);
				code.op(IlOps.RET, 0, 0);
			case TReturn(e1):
				if (code.depth != 0) throw new Unsupported("`return` inside expressions", false);
				if (this.ret.match(LVoid)) {
					// `return f()` with a Void f.
					texpr(RVoid, e1);
					if (code.reachable()) code.op(IlOps.RET, 0, 0);
				} else {
					texpr(RValue(this.ret), e1);
					code.op(IlOps.RET, 1, 0);
				}
			case TParenthesis(e1) | TMeta(_, e1):
				texpr(ret, e1);
			case TCast(e1, null):
				// A cast between instantiations is reported at the cast.
				if (!isNullConst(e1)) {
					var from = try sig(e1.type) catch (_:Unsupported) null, to = try sig(e.type) catch (_:Unsupported) null;
					if (from != null && to != null) checkInstantiationCast(from, to);
				}
				texpr(switch (ret) {
					case RValue(null): RValue(sig(e.type));
					case r: r;
				}, e1);
			case TBinop(OpAssign, lhs, rhs):
				assign(ret, lhs, rhs);
			case TBinop(OpAssignOp(op), lhs, rhs):
				compound(ret, op, lhs, rhs);
			case TBinop(op, e1, e2):
				binary(ret, e, op, e1, e2);
			case TUnop(op, flag, e1):
				unary(ret, e, op, flag, e1);
			case TIf(cond, eif, eelse):
				ifExpr(ret, e, cond, eif, eelse);
			case TWhile(cond, body, flag):
				whileLoop(ret, cond, body, flag);
			case TSwitch(subject, cases, def):
				switchExpr(ret, e, subject, cases, def);
			case TBreak:
				if (loops.length == 0) throw new Unsupported("`break` outside a loop", false);
				// The loop's labels are reached with an empty stack.
				if (code.depth != 0) throw new Unsupported("`break` inside expressions", false);
				code.branch(IlOps.BR, loops[loops.length - 1].brk);
			case TContinue:
				if (loops.length == 0) throw new Unsupported("`continue` outside a loop", false);
				if (code.depth != 0) throw new Unsupported("`continue` inside expressions", false);
				code.branch(IlOps.BR, loops[loops.length - 1].cont);
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
			case TArray(e1, e2):
				arrayRead(ret, e1, e2);
			case TObjectDecl(_):
				throw new Unsupported("anonymous objects", true);
			case TArrayDecl(el):
				arrayLiteral(ret, e, el);
			case TFor(_, _, _):
				throw new Unsupported("for loops", true);
			case TTry(_, _):
				throw new Unsupported("try/catch", false);
			case TThrow(_):
				throw new Unsupported("`throw`", false);
			case TCast(e1, TClassDecl(_)):
				checkedCast(ret, e, e1);
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
				var usesPoisoned = usesPoisonedVar(s);
				switch (s.expr) {
					case TVarExpr(v, _): poisoned.set(v.id, true);
					case _:
				}
				if (!usesPoisoned) onError(u);
			}
		}
	}

	function usesPoisonedVar(e:TExpr):Bool {
		return switch (e.expr) {
			case TLocal(v): poisoned.exists(v.id);
			case _: TexprTools.checkExpr(usesPoisonedVar, e);
		}
	}

	function staticField(c:TClass, cf:TClassField):{token:Int, sig:IlSigNorm} {
		g.types.checkKept(TClassDecl(c));
		var plan = g.ownerOf.get(cf);
		if (plan == null || !g.fieldTokens.exists(cf)) throw "internal error: no field " + Globals.sTypePath(c.path) + "." + cf.name;
		return {token: g.memberOf(plan, staticOwner(plan), cf), sig: g.fieldSigs.get(cf)};
	}

	// As gencs writes it, a static member of a generic class is reached through the instantiation
	// with object for each type parameter.
	static function staticOwner(plan:ClassPlan):IlSigNorm {
		return DotnetCtx.instanceOf(plan, [for (_ in plan.classParams) LObject]);
	}

	// The type arguments of `target`, a superclass or interface of `c` or `c` itself, when `c` has
	// `params`.
	static function argsAt(c:TClass, params:TParams, target:TClass):Null<TParams> {
		if (c == target) return params;
		var supers = c.interfaces.copy();
		if (c.superClass != null) supers.push(c.superClass);
		for (s in supers) {
			var r = argsAt(s.c, [for (t in s.params) TypeFunctions.applyParams(c.params, params, t)], target);
			if (r != null) return r;
		}
		return null;
	}

	// The type arguments of the class `plan` declares, as an access through `c` with `params` sees them.
	function ownerArgs(c:TClass, params:TParams, plan:ClassPlan):TParams {
		if (plan.classParams.length == 0) return [];
		var r = argsAt(c, params, plan.c);
		if (r == null) throw "internal error: " + plan.hxPath + " is not a supertype of " + Globals.sTypePath(c.path);
		return r;
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
			case TArray(e1, e2) if (isNativeArray(e1.type)):
				var elem = pushArrayAndIndex(e1, e2);
				texpr(RValue(elem), rhs);
				var tmp = needVal(ret) ? keepTop(elem) : -1;
				code.opToken(IlOps.STELEM, g.typeTokenOf(elem), 3, 0);
				if (tmp >= 0) {
					code.ldloc(tmp);
					coerce(elem, ret);
				}
			case TArray(e1, e2) if (arrayOf(e1.type) != null):
				var m = arrayAccessor(e1.type, "__set");
				receiver(e1, m.owner);
				texpr(RValue(m.args[0]), e2);
				texpr(RValue(m.args[1]), rhs);
				code.opToken(IlOps.CALLVIRT, m.token, 3, 1);
				// __set returns the value it stored.
				coerce(m.ret, ret);
			case TField(_, FStatic(c, cf)) if (!isExtern(c)):
				var f = staticField(c, cf);
				texpr(RValue(f.sig), rhs);
				if (needVal(ret)) code.op(IlOps.DUP, 1, 2);
				code.opToken(IlOps.STSFLD, f.token, 1, 0);
				if (needVal(ret)) coerce(f.sig, ret);
			case TField(obj, FInstance(c, cparams, cf)) if (!isExtern(c) && !isStringClass(c)):
				var f = instanceField(c, cparams, cf);
				receiver(obj, f.owner, true);
				texpr(RValue(f.sig), rhs);
				var tmp = needVal(ret) ? keepTop(f.sig) : -1;
				code.opToken(IlOps.STFLD, f.token, 2, 0);
				if (tmp >= 0) {
					code.ldloc(tmp);
					coerce(f.sig, ret);
				}
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c)):
				var isStatic = fa.match(FStatic(_, _));
				var inst = instantiation(c, fa);
				var parent = parentOf(c, inst);
				switch (g.externs.field(c, cf)) {
					case XField(open, initOnly):
						var s = ExternMembers.subst(open, inst);
						if (initOnly) throw new Unsupported("assignments to read-only .NET fields", true);
						if (needVal(ret)) throw new Unsupported("the value of an assignment to a .NET field", false);
						if (!isStatic) receiver(obj, parent);
						texpr(RValue(s), rhs);
						var token = g.mb.memberRef(g.typeTokenOf(parent), ExternMembers.memberName(cf), g.sigs.field(open));
						code.opToken(isStatic ? IlOps.STSFLD : IlOps.STFLD, token, isStatic ? 1 : 2, 0);
					case XProperty(open, _, setter) if (setter != null):
						var s = ExternMembers.subst(open, inst);
						if (needVal(ret)) throw new Unsupported("the value of an assignment to a .NET property", false);
						if (!isStatic) receiver(obj, parent);
						texpr(RValue(s), rhs);
						var token = g.mb.memberRef(g.typeTokenOf(parent), setter, g.sigs.method(!isStatic, LVoid, [open], 0));
						code.opToken(isStatic || DotnetTypes.isValueType(parent) ? IlOps.CALL : IlOps.CALLVIRT, token, isStatic ? 1 : 2, 0);
					case _:
						throw new Unsupported("assignments to a read-only .NET member", true);
				}
			case _:
				throw new Unsupported("this kind of assignment", false);
		}
	}

	static function strip(e:TExpr):TExpr {
		return switch (e.expr) {
			case TParenthesis(e1) | TMeta(_, e1): strip(e1);
			case _: e;
		}
	}

	static function isNullConst(e:TExpr):Bool return strip(e).expr.match(TConst(TNull));

	static function constInt(e:TExpr):Null<Int> {
		return switch (strip(e).expr) {
			case TConst(TInt(v)): v;
			case _: null;
		}
	}

	static function isStringClass(c:TClass):Bool return c.path.pack.length == 0 && c.path.name == "String";

	static function isNumeric(s:IlSigNorm):Bool return s.match(LInt32 | LUInt32 | LFloat64);

	function operandSig(op:Binop, e:TExpr):IlSigNorm {
		var s = sig(e.type);
		if (!isNumeric(s)) throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
		return s;
	}

	// Dynamic reaches Bool and Float through Runtime.toBool and toDouble in gencs, which are not
	// ported yet.
	function noDynamic(e:TExpr, what:String):Void {
		if (sig(strip(e).type).match(LObject)) throw new Unsupported(what, false);
	}

	function binary(ret:Ret, e:TExpr, op:Binop, e1:TExpr, e2:TExpr):Void {
		switch (op) {
			case OpBoolAnd | OpBoolOr:
				boolValue(ret, e);
			case OpEq | OpNotEq | OpLt | OpLte | OpGt | OpGte:
				compare(ret, op, e1, e2);
			case OpAdd if (sig(e.type).match(LString)):
				pushString(e1);
				pushString(e2);
				concat();
				coerce(LString, ret);
			case OpAdd | OpSub | OpMult | OpDiv | OpMod | OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr:
				var s1 = operandSig(op, e1), s2 = operandSig(op, e2);
				var t = sig(e.type);
				// Bitwise operators and shifts take Int operands only.
				if (!isArith(op) && !(isIntLike(s1) && isIntLike(s2) && isIntLike(t)))
					throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
				texpr(RValue(t), e1);
				numericTail(op, t, e2);
				coerce(t, ret);
			case _:
				throw new Unsupported("the " + Ast.sBinop(op) + " operator", false);
		}
	}

	static function isArith(op:Binop):Bool return op.match(OpAdd | OpSub | OpMult | OpDiv | OpMod);

	// The left operand, of type `t`, is on the stack; this pushes the right one and applies `op`.
	function numericTail(op:Binop, t:IlSigNorm, e2:TExpr):Void {
		var bad = new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
		if (!isNumeric(t)) throw bad;
		if (!isArith(op) && !isIntLike(t)) throw bad;
		var unsigned = t.match(LUInt32);
		if (op.match(OpDiv) && !t.match(LFloat64)) throw bad;
		switch (op) {
			case OpShl | OpShr | OpUShr:
				// The count is masked as C# does.
				var n = constInt(e2);
				if (n != null) {
					code.ldcI4(n & 31);
				} else {
					texpr(RValue(LInt32), e2);
					code.ldcI4(31);
					code.op(IlOps.AND, 2, 1);
				}
				code.op(op.match(OpShl) ? IlOps.SHL : op.match(OpShr) && !unsigned ? IlOps.SHR : IlOps.SHR_UN, 2, 1);
			case _:
				texpr(RValue(t), e2);
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

	function compare(ret:Ret, op:Binop, e1:TExpr, e2:TExpr):Void {
		var equality = op.match(OpEq | OpNotEq);
		var isFloat = false;
		// A UInt operand makes an Int comparison unsigned, as UInt's operators take two UInts.
		var unsigned = false;
		var string = false;
		if (isNullConst(e1) || isNullConst(e2)) {
			if (!equality) throw new Unsupported("comparing null with the " + Ast.sBinop(op) + " operator", false);
			var other = isNullConst(e1) ? e2 : e1;
			if (isNullConst(other)) throw new Unsupported("comparing null with null", false);
			var s = sig(other.type);
			if (DotnetTypes.isValueType(s) || isTypeParam(s)) throw new Unsupported("comparing a value type with null", false);
			texpr(RValue(null), e1);
			texpr(RValue(null), e2);
		} else {
			var s1 = sig(e1.type), s2 = sig(e2.type);
			if (isNumeric(s1) && isNumeric(s2)) {
				var t = s1.match(LFloat64) || s2.match(LFloat64) ? LFloat64 : s1.match(LUInt32) || s2.match(LUInt32) ? LUInt32 : LInt32;
				isFloat = t.match(LFloat64);
				unsigned = t.match(LUInt32);
				texpr(RValue(t), e1);
				texpr(RValue(t), e2);
			} else if (equality && s1.match(LBool) && s2.match(LBool)) {
				texpr(RValue(LBool), e1);
				texpr(RValue(LBool), e2);
			} else if (equality && s1.match(LString) && s2.match(LString)) {
				string = true;
				texpr(RValue(LString), e1);
				texpr(RValue(LString), e2);
			} else if (equality && isReference(s1) && isReference(s2) && !s1.match(LObject) && !s2.match(LObject)) {
				texpr(RValue(null), e1);
				texpr(RValue(null), e2);
			} else {
				throw new Unsupported("the " + Ast.sBinop(op) + " operator on these types", false);
			}
		}
		if (string) {
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
		coerce(LBool, ret);
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
				// Dynamic would need Runtime.toBool (null is false); an unbox here would throw.
				noDynamic(e, "Dynamic as a condition");
				texpr(RValue(LBool), e);
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
		coerce(LBool, ret);
	}

	function unary(ret:Ret, e:TExpr, op:Unop, flag:UnopFlag, e1:TExpr):Void {
		switch (op) {
			case Not:
				noDynamic(e1, "Dynamic with the ! operator");
				texpr(RValue(LBool), e1);
				not();
				coerce(LBool, ret);
			case Neg:
				var t = sig(e.type);
				if (!isNumeric(t)) throw new Unsupported("the - operator on these types", false);
				texpr(RValue(t), e1);
				code.op(IlOps.NEG, 1, 1);
				coerce(t, ret);
			case NegBits:
				var t = sig(e.type);
				if (!t.match(LInt32)) throw new Unsupported("the ~ operator on these types", false);
				texpr(RValue(t), e1);
				code.op(IlOps.NOT, 1, 1);
				coerce(t, ret);
			case Increment | Decrement:
				incDec(ret, op.match(Increment), flag.match(Postfix), e1);
			case Spread:
				throw new Unsupported("the spread operator", false);
		}
	}

	// A local or a Haxe class's static variable, which can be loaded and stored without a receiver; an
	// instance variable; an array element, whose array and index are kept in temporaries.
	function place(e:TExpr):Null<Place> {
		switch (e.expr) {
			case TParenthesis(e1) | TMeta(_, e1):
				return place(e1);
			case TArray(e1, e2) if (isNativeArray(e1.type) || arrayOf(e1.type) != null):
				var native = isNativeArray(e1.type);
				var get = native ? null : arrayAccessor(e1.type, "__get");
				var set = native ? null : arrayAccessor(e1.type, "__set");
				var elem = native ? vectorElement(sig(e1.type)) : get.ret;
				var arr = -1, idx = -1;
				function reload() {
					code.ldloc(arr);
					code.ldloc(idx);
				}
				return {
					sig: elem,
					receiver: true,
					prepare: () -> {
						var arrSig = native ? sig(e1.type) : get.owner;
						texpr(RValue(arrSig), e1);
						arr = code.addLocal(arrSig);
						code.stloc(arr);
						var idxSig = native ? indexSig(e2) : get.args[0];
						texpr(RValue(idxSig), e2);
						idx = code.addLocal(idxSig);
						code.stloc(idx);
						reload();
					},
					load: () -> {
						reload();
						if (native) code.opToken(IlOps.LDELEM, g.typeTokenOf(elem), 2, 1) else code.opToken(IlOps.CALLVIRT, get.token, 2, 1);
					},
					store: () -> {
						if (native) {
							code.opToken(IlOps.STELEM, g.typeTokenOf(elem), 3, 0);
						} else {
							code.opToken(IlOps.CALLVIRT, set.token, 3, 1);
							code.op(IlOps.POP, 1, 0);
						}
					}
				};
			case TLocal(v):
				var s = slot(v);
				return {sig: s.sig, receiver: false, prepare: () -> {}, load: () -> load(s), store: () -> store(s)};
			case TField(_, FStatic(c, cf)) if (!isExtern(c) && cf.kind.match(Var(_))):
				var f = staticField(c, cf);
				return {
					sig: f.sig,
					receiver: false,
					prepare: () -> {},
					load: () -> code.opToken(IlOps.LDSFLD, f.token, 0, 1),
					store: () -> code.opToken(IlOps.STSFLD, f.token, 1, 0)
				};
			case TField(obj, FInstance(c, cparams, cf)) if (!isExtern(c) && !isStringClass(c) && cf.kind.match(Var(_))):
				var f = instanceField(c, cparams, cf);
				return {
					sig: f.sig,
					receiver: true,
					prepare: () -> receiver(obj, f.owner, true),
					load: () -> {
						code.op(IlOps.DUP, 1, 2);
						code.opToken(IlOps.LDFLD, f.token, 1, 1);
					},
					store: () -> code.opToken(IlOps.STFLD, f.token, 2, 0)
				};
			case _:
				return null;
		}
	}

	function incDec(ret:Ret, increment:Bool, postfix:Bool, e1:TExpr):Void {
		var p = place(e1);
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
		coerce(p.sig, ret);
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

	function compound(ret:Ret, op:Binop, lhs:TExpr, rhs:TExpr):Void {
		var p = place(lhs);
		if (p == null) throw new Unsupported("this kind of assignment", false);
		p.prepare();
		p.load();
		if (op.match(OpAdd) && p.sig.match(LString)) {
			stringifyTop(LString);
			pushString(rhs);
			concat();
		} else {
			numericTail(op, p.sig, rhs);
		}
		var tmp = needVal(ret) ? keep(p) : -1;
		p.store();
		if (needVal(ret)) {
			if (tmp >= 0) code.ldloc(tmp);
			coerce(p.sig, ret);
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
				texpr(RValue(LString), inner);
				return;
			case TConst(TNull):
				code.opToken(IlOps.LDSTR, g.mb.userString("null"), 0, 1);
				return;
			case TBinop(OpAdd, _, _) if (sig(inner.type).match(LString)):
				// A concatenation is never null.
				texpr(RValue(LString), inner);
				return;
			case _:
		}
		var s = sig(e.type);
		stringKind(s);
		texpr(RValue(s), e);
		stringifyTop(s);
	}

	// Throws for the types a String conversion does not handle yet.
	static function stringKind(s:IlSigNorm):Void {
		switch (s) {
			case LObject:
				throw new Unsupported("Dynamic in string concatenation", false);
			case LTypeParam(_) | LMethodTypeParam(_):
				throw new Unsupported("generic values in string concatenation", true);
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

	// The type of a value `if` or `switch`: the surrounding one, else its own.
	function valueRet(ret:Ret, e:TExpr):Ret {
		return switch (ret) {
			case RValue(null):
				var t = sig(e.type);
				t.match(LVoid) ? ret : RValue(t);
			case _: ret;
		}
	}

	function ifExpr(ret:Ret, e:TExpr, cond:TExpr, eif:TExpr, eelse:Null<TExpr>):Void {
		if (eelse == null && needVal(ret)) throw new Unsupported("Void values", true);
		var r = valueRet(ret, e);
		var other = code.newLabel();
		jumpIf(cond, other, false);
		texpr(r, eif);
		if (eelse == null) {
			code.markIfUsed(other);
			return;
		}
		var end = code.newLabel();
		if (code.reachable()) code.branch(IlOps.BR, end);
		code.markIfUsed(other);
		texpr(r, eelse);
		code.markIfUsed(end);
	}

	function whileLoop(ret:Ret, cond:TExpr, body:TExpr, flag:WhileFlag):Void {
		// A loop head is a backward branch target, which needs an empty stack.
		if (code.depth != 0) throw new Unsupported("loops inside expressions", true);
		var top = code.newLabel(), cont = code.newLabel(), brk = code.newLabel();
		code.mark(top);
		var isDo = flag.match(DoWhile);
		loops.push({brk: brk, cont: isDo ? cont : top});
		try {
			if (isDo) {
				texpr(RVoid, body);
				code.markIfUsed(cont);
				jumpIf(cond, top, true);
			} else {
				jumpIf(cond, brk, false);
				texpr(RVoid, body);
				if (code.reachable()) code.branch(IlOps.BR, top);
			}
		} catch (x:Dynamic) {
			loops.pop();
			throw x;
		}
		loops.pop();
		code.markIfUsed(brk);
		coerce(LVoid, ret);
	}

	// A chain of comparisons in case order, then the default.
	function switchExpr(ret:Ret, e:TExpr, subject:TExpr, cases:Array<TSwitchCase>, def:Null<TExpr>):Void {
		if (def == null && needVal(ret)) throw new Unsupported("switch expressions without a default", true);
		var r = valueRet(ret, e);
		var st = sig(subject.type);
		var isString = st.match(LString);
		if (!isString && !st.match(LInt32 | LBool)) throw new Unsupported("switch on this type", false);
		var local:Null<Slot> = null;
		switch (strip(subject).expr) {
			case TLocal(v): local = slot(v);
			case _:
		}
		var tmp = -1;
		if (local == null) {
			texpr(RValue(st), subject);
			tmp = code.addLocal(st);
			code.stloc(tmp);
		}
		var bodies = [for (_ in cases) code.newLabel()];
		var eq = isString ? g.mb.memberRef(g.typeTokenOf(LString), "op_Equality", g.sigs.method(false, LBool, [LString, LString], 0)) : 0;
		for (i in 0...cases.length) for (v in cases[i].values) {
			if (local != null) load(local) else code.ldloc(tmp);
			texpr(RValue(st), v);
			if (isString) {
				code.opToken(IlOps.CALL, eq, 2, 1);
				code.branch(IlOps.BRTRUE, bodies[i]);
			} else {
				code.branch(IlOps.BEQ, bodies[i]);
			}
		}
		var end = code.newLabel();
		var defLabel = def == null ? end : code.newLabel();
		code.branch(IlOps.BR, defLabel);
		for (i in 0...cases.length) {
			code.markIfUsed(bodies[i]);
			texpr(r, cases[i].expr);
			if (code.reachable()) code.branch(IlOps.BR, end);
		}
		if (def != null) {
			code.mark(defLabel);
			texpr(r, def);
		}
		code.markIfUsed(end);
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

	// The object an instance member is reached through; a value type's address. A field store needs
	// the address of a variable, not of a copy.
	function receiver(obj:TExpr, parent:IlSigNorm, forStore = false):Void {
		if (!DotnetTypes.isValueType(parent)) {
			texpr(RValue(parent), obj);
			return;
		}
		if (pushAddress(obj, forStore)) return;
		// A value with no home, such as a call's result: C# works on a copy too.
		if (forStore) throw new Unsupported("assignments to fields of struct values", true);
		texpr(RValue(parent), obj);
		var tmp = code.addLocal(parent);
		code.stloc(tmp);
		code.ldloca(tmp);
	}

	// Pushes the address of the value-type variable `e` names, as C# takes it for a member access: a
	// local, an argument, a struct's `this`, or an instance or static field (of a field, and so on).
	// False, with nothing pushed, for anything else, and for a readonly .NET field, which C# copies. With
	// `forStore`, a chain that starts at a value with no home throws, as C# rejects a store to it.
	function pushAddress(e:TExpr, forStore:Bool):Bool {
		switch (strip(e).expr) {
			case TLocal(v):
				var s = slot(v);
				if (s.arg) code.ldarga(s.index) else code.ldloca(s.index);
				return true;
			case TConst(TThis) if (thisSig != null && DotnetTypes.isValueType(thisSig)):
				code.ldarg(0);
				return true;
			case TField(obj, FInstance(c, cparams, cf)) if (!isExtern(c) && !isStringClass(c) && cf.kind.match(Var(_))):
				var f = instanceField(c, cparams, cf);
				receiver(obj, f.owner, forStore);
				code.opToken(IlOps.LDFLDA, f.token, 1, 1);
				return true;
			case TField(_, FStatic(c, cf)) if (!isExtern(c) && cf.kind.match(Var(_))):
				code.opToken(IlOps.LDSFLDA, staticField(c, cf).token, 0, 1);
				return true;
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c) && cf.kind.match(Var(_))):
				switch (g.externs.field(c, cf)) {
					case XField(open, false):
						var isStatic = fa.match(FStatic(_, _));
						var parent = parentOf(c, instantiation(c, fa));
						if (!isStatic) receiver(obj, parent, forStore);
						var token = g.mb.memberRef(g.typeTokenOf(parent), ExternMembers.memberName(cf), g.sigs.field(open));
						code.opToken(isStatic ? IlOps.LDSFLDA : IlOps.LDFLDA, token, isStatic ? 0 : 1, 1);
						return true;
					case _:
						return false;
				}
			case _:
				return false;
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
			case FInstance(c, _, cf) if (isStringClass(c)):
				if (cf.name != "length") throw new Unsupported("the String field " + cf.name, false);
				texpr(RValue(LString), obj);
				callString("get_Length", LInt32, []);
				coerce(LInt32, ret);
			case FInstance(_, _, cf) if (cf.name == "Length" && isNativeArray(obj.type)):
				nativeLength(ret, obj);
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
					case XField(open, _):
						if (!isStatic) receiver(obj, parent);
						var token = g.mb.memberRef(g.typeTokenOf(parent), ExternMembers.memberName(cf), g.sigs.field(open));
						code.opToken(isStatic ? IlOps.LDSFLD : IlOps.LDFLD, token, isStatic ? 0 : 1, 1);
						coerce(ExternMembers.subst(open, inst), ret);
					case XProperty(open, getter, _) if (getter != null):
						if (!isStatic) receiver(obj, parent);
						var token = g.mb.memberRef(g.typeTokenOf(parent), getter, g.sigs.method(!isStatic, open, [], 0));
						code.opToken(isStatic || DotnetTypes.isValueType(parent) ? IlOps.CALL : IlOps.CALLVIRT, token, isStatic ? 0 : 1, 1);
						coerce(ExternMembers.subst(open, inst), ret);
					case _:
						throw new Unsupported("reading a write-only .NET property", false);
				}
			case FInstance(c, cparams, cf):
				if (!cf.kind.match(Var(_))) throw new Unsupported("method closures", true);
				var f = instanceField(c, cparams, cf);
				receiver(obj, f.owner);
				code.opToken(IlOps.LDFLD, f.token, 1, 1);
				coerce(f.sig, ret);
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

	// A native array's Length: ldlen, then the native int as an Int.
	function nativeLength(ret:Ret, obj:TExpr):Void {
		texpr(RValue(sig(obj.type)), obj);
		code.op(IlOps.LDLEN, 1, 1);
		code.op(IlOps.CONV_I4, 1, 1);
		coerce(LInt32, ret);
	}

	static function isStd(c:TClass):Bool return c.path.pack.length == 0 && c.path.name == "Std";

	// The expression whose static type Std.string can print directly, else null.
	function stringArg(e:TExpr):Null<TExpr> {
		var inner = switch (strip(e).expr) {
			case TCast(x, null): strip(x);
			case _: strip(e);
		}
		try {
			stringKind(sig(inner.type));
		} catch (_:Unsupported) {
			return null;
		}
		return inner;
	}

	// An instance member of System.String, with the receiver on the stack.
	function callString(name:String, retSig:IlSigNorm, argSigs:Array<IlSigNorm>):Void {
		var token = g.mb.memberRef(g.typeTokenOf(LString), name, g.sigs.method(true, retSig, argSigs, 0));
		code.opToken(IlOps.CALLVIRT, token, argSigs.length + 1, retSig.match(LVoid) ? 0 : 1);
	}

	// String members, as gencs maps them.
	function stringCall(ret:Ret, obj:TExpr, cf:TClassField, args:Array<TExpr>):Void {
		switch (cf.name) {
			case "toUpperCase" | "toLowerCase":
				texpr(RValue(LString), obj);
				callString(cf.name == "toUpperCase" ? "ToUpperInvariant" : "ToLowerInvariant", LString, []);
				coerce(LString, ret);
			case "toString":
				texpr(RValue(LString), obj);
				coerce(LString, ret);
			case "charAt" | "charCodeAt" | "indexOf" | "lastIndexOf" | "split" | "substring" | "substr":
				stringExtCall(ret, cf.name, obj, args);
			case _:
				// The private externs name the System.String member.
				var argSigs, retSig;
				switch (TypeFunctions.follow(cf.type)) {
					case TFun(fsig):
						argSigs = [for (a in fsig.args) sig(a.t)];
						retSig = sig(fsig.ret);
					case _:
						throw "internal error: String." + cf.name + " is not a function";
				}
				texpr(RValue(LString), obj);
				pushArgs(args, argSigs);
				callString(ExternMembers.memberName(cf), retSig, argSigs);
				coerce(retSig, ret);
		}
	}

	// A static method of cs.internal.StringExt (haxe.lang.StringExt in the assembly), the receiver first.
	function stringExtCall(ret:Ret, name:String, receiver:Null<TExpr>, args:Array<TExpr>):Void {
		var found = null;
		for (mt in g.ctx.types) switch (mt) {
			case TClassDecl(c) if (DotnetTypes.haxePath(mt) == "cs.internal.StringExt"):
				g.types.checkKept(mt);
				var cf = c.statics.get(name);
				var token = cf == null ? null : g.methodTokens.get(cf);
				if (token != null) found = {token: token, m: g.methodSigs.get(cf)};
			case _:
		}
		if (found == null) throw new Unsupported("String." + name, false);
		var all = receiver == null ? args : [receiver].concat(args);
		pushArgs(all, found.m.args);
		code.opToken(IlOps.CALL, found.token, all.length, found.m.ret.match(LVoid) ? 0 : 1);
		coerce(found.m.ret, ret);
	}

	function pushArgs(args:Array<TExpr>, slots:Array<IlSigNorm>):Void {
		if (args.length != slots.length) throw new Unsupported("calls that leave out arguments", true);
		for (i in 0...args.length) switch (slots[i]) {
			case LManagedPointer(t):
				// cs.Ref and cs.Out: the address of a variable of exactly that type, as C#'s ref and out.
				var s = try sig(args[i].type) catch (_:Unsupported) null;
				if (s == null || !IlPaths.sigEq(s, t) || !pushAddress(args[i], true))
					throw new Unsupported("by-reference arguments that are not variables of the parameter's type", true);
			case s:
				texpr(RValue(s), args[i]);
		}
	}

	function call(ret:Ret, e:TExpr, callee:TExpr, args:Array<TExpr>):Void {
		switch (callee.expr) {
			case TField(_, FStatic(c, cf)) if (isStd(c) && cf.name == "int" && args.length == 1):
				// As gencs writes Std.int: a C# cast.
				noDynamic(args[0], "Dynamic in Std.int");
				texpr(RValue(LFloat64), args[0]);
				code.op(IlOps.CONV_I4, 1, 1);
				coerce(LInt32, ret);
			case TField(_, FStatic(c, cf)) if (isStd(c) && cf.name == "string" && args.length == 1 && stringArg(args[0]) != null):
				// A value of a known type prints as in a concatenation, Bool as true or false.
				pushString(stringArg(args[0]));
				coerce(LString, ret);
			case TField(obj, FInstance(c, _, cf)) if (isStringClass(c)):
				stringCall(ret, obj, cf, args);
			case TField(obj, FInstance(_, _, cf)) if (cf.name == "get_Length" && args.length == 0 && isNativeArray(obj.type)):
				nativeLength(ret, obj);
			case TField(_, FStatic(c, cf)) if (isStringClass(c)):
				if (cf.name != "fromCharCode") throw new Unsupported("the String function " + cf.name, false);
				stringExtCall(ret, cf.name, null, args);
			case TField(_, FStatic(c, cf)) if (!isExtern(c)):
				g.types.checkKept(TClassDecl(c));
				var target = pickOverload(c, [], cf, args, true);
				var plan = g.ownerOf.get(target);
				if (plan == null || !g.methodTokens.exists(target)) throw "internal error: no method " + Globals.sTypePath(c.path) + "." + cf.name;
				var m = methodRef(plan, staticOwner(plan), [], target, target.type, callee.type);
				pushArgs(args, m.args);
				code.opToken(IlOps.CALL, m.token, args.length, m.ret.match(LVoid) ? 0 : 1);
				coerce(m.ret, ret);
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c)):
				externCall(ret, obj, fa, c, cf, args, callee.type);
			case TConst(TSuper):
				superCtorCall(args);
				coerce(LVoid, ret);
			case TField(obj, FInstance(c, params, cf)):
				if (!cf.kind.match(Method(_))) throw new Unsupported("calls of function values", true);
				var m = haxeMethod(c, params, cf, args, callee.type);
				// super.m() calls the base class's method itself.
				var isSuper = strip(obj).expr.match(TConst(TSuper));
				if (isSuper) code.ldarg(0) else receiver(obj, m.owner);
				pushArgs(args, m.args);
				var op = isSuper || DotnetTypes.isValueType(m.owner) ? IlOps.CALL : IlOps.CALLVIRT;
				code.opToken(op, m.token, args.length + 1, m.ret.match(LVoid) ? 0 : 1);
				coerce(m.ret, ret);
			case TIdent(_):
				throw new Unsupported("untyped code", false);
			case _:
				throw new Unsupported("calls of function values", true);
		}
	}

	// The overload a call of a Haxe method reaches, as the JVM generator picks it.
	function pickOverload(c:TClass, params:TParams, cf:TClassField, args:Array<TExpr>, isStatic:Bool):TClassField {
		if (cf.overloads.length == 0 && !TypeFunctions.hasClassFieldFlag(cf, CfOverload)) return cf;
		var mapType = (t:T) -> TypeFunctions.applyParams(c.params, params, t);
		var r = isStatic ? OverloadResolution.filterOverloads(OverloadResolution.findOverload(mapType, c, cf, args)) : OverloadResolution.maybeResolveInstanceOverload(false,
			mapType, c, cf, args);
		if (r == null) throw new Unsupported("this call of an overloaded method", false);
		return r.cf;
	}

	// A Haxe class's instance variable as an access through `c` with `params` reaches it: its token, its
	// type there and the type of the class declaring it.
	function instanceField(c:TClass, params:TParams, cf:TClassField):{token:Int, sig:IlSigNorm, owner:IlSigNorm} {
		g.types.checkKept(TClassDecl(c));
		var plan = g.ownerOf.get(cf);
		if (plan == null || !g.fieldTokens.exists(cf)) {
			if (!TypeFunctions.isPhysicalField(cf)) throw new Unsupported("this kind of field access", false);
			throw "internal error: no field " + Globals.sTypePath(c.path) + "." + cf.name;
		}
		var inst = [for (t in ownerArgs(c, params, plan)) sig(t)];
		var owner = DotnetCtx.instanceOf(plan, inst);
		return {token: g.memberOf(plan, owner, cf), sig: DotnetTypes.substitute(g.fieldSigs.get(cf), inst, []), owner: owner};
	}

	// A method's token as a call reaches it, with a MethodSpec for a generic method, and its argument
	// and return types there. `declared` is the method's type with the class's type arguments applied;
	// the call's `calleeType` gives the method's own.
	function methodRef(plan:ClassPlan, owner:IlSigNorm, inst:Array<IlSigNorm>, target:TClassField, declared:T,
			calleeType:T):{token:Int, args:Array<IlSigNorm>, ret:IlSigNorm} {
		var token = g.memberOf(plan, owner, target);
		var margs = [for (t in DotnetTypes.inferParams(target.params, declared, calleeType)) sig(t)];
		if (margs.length > 0) token = g.mb.methodSpec(token, g.sigs.methodSpec(margs));
		var m = g.methodSigs.get(target);
		return {
			token: token,
			args: [for (a in m.args) DotnetTypes.substitute(a, inst, margs)],
			ret: DotnetTypes.substitute(m.ret, inst, margs)
		};
	}

	// A Haxe class's instance method, the overload the call reaches.
	function haxeMethod(c:TClass, params:TParams, cf:TClassField, args:Array<TExpr>, calleeType:T):{token:Int, args:Array<IlSigNorm>, ret:IlSigNorm, owner:IlSigNorm} {
		g.types.checkKept(TClassDecl(c));
		var target = pickOverload(c, params, cf, args, false);
		var plan = g.ownerOf.get(target);
		if (plan == null || !g.methodTokens.exists(target)) throw "internal error: no method " + Globals.sTypePath(c.path) + "." + cf.name;
		var hxArgs = ownerArgs(c, params, plan);
		var inst = [for (t in hxArgs) sig(t)];
		var owner = DotnetCtx.instanceOf(plan, inst);
		var declared = plan.c == null ? target.type : TypeFunctions.applyParams(plan.c.params, hxArgs, target.type);
		var m = methodRef(plan, owner, inst, target, declared, calleeType);
		return {token: m.token, args: m.args, ret: m.ret, owner: owner};
	}

	// A method of a referenced assembly; super.m() calls the base method itself.
	function externCall(ret:Ret, obj:TExpr, fa:TFieldAccess, c:TClass, cf:TClassField, args:Array<TExpr>, calleeType:T):Void {
		var isStatic = fa.match(FStatic(_, _));
		var isSuper = !isStatic && strip(obj).expr.match(TConst(TSuper));
		var m = g.externs.method(c, cf);
		// A generic method's type arguments, inferred from the call as for a Haxe method.
		var margs:Array<IlSigNorm> = [];
		if (m.genericCount > 0) {
			if (cf.params.length != m.genericCount) throw new Unsupported("generic .NET methods", true);
			var declared = switch (fa) {
				case FInstance(_, params, _): TypeFunctions.applyParams(c.params, params, cf.type);
				case _: cf.type;
			}
			margs = [for (t in DotnetTypes.inferParams(cf.params, declared, calleeType)) sig(t)];
		}
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
		if (isSuper) code.ldarg(0) else if (!isStatic) receiver(obj, parent);
		pushArgs(args, [for (a in ilArgs) DotnetTypes.substitute(a, parentArgs, margs)]);
		var token = g.mb.memberRef(g.typeTokenOf(parent), m.name, g.sigs.methodSig(m.sig, m.genericCount));
		if (margs.length > 0) token = g.mb.methodSpec(token, g.sigs.methodSpec(margs));
		var retSlot = DotnetTypes.substitute(ilRet, parentArgs, margs);
		var op = isStatic || isSuper || DotnetTypes.isValueType(parent) ? IlOps.CALL : IlOps.CALLVIRT;
		code.opToken(op, token, args.length + (isStatic ? 0 : 1), retSlot.match(LVoid) ? 0 : 1);
		if (retSlot.match(LVoid) && needVal(ret)) throw new Unsupported("the value of a .NET setter call", false);
		coerce(retSlot, ret);
	}

	// A .NET constructor: its MemberRef, with the arguments pushed.
	function externCtor(c:TClass, params:TParams, args:Array<TExpr>):{token:Int, parent:IlSigNorm} {
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
		return {token: g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.methodSig(m.sig, 0)), parent: parent};
	}

	// A Haxe class's constructor: the one the arguments reach, or the implicit one; 0 for a struct's
	// parameterless one, which is not declared.
	function haxeCtor(c:TClass, params:TParams, args:Array<TExpr>):{token:Int, args:Array<IlSigNorm>, owner:IlSigNorm} {
		g.types.checkKept(TClassDecl(c));
		var plan = g.planOf.get(c);
		if (plan == null) throw "internal error: no plan for " + Globals.sTypePath(c.path);
		var inst = [for (p in params) sig(p)];
		var owner = DotnetCtx.instanceOf(plan, inst);
		var m:Null<MethodPlan> = null;
		if (c.constructor == null || TypeFunctions.hasClassFieldFlag(c.constructor, CfExtern)) {
			for (x in plan.methods) if (x.name == ".ctor") m = x;
		} else {
			var r = OverloadResolution.maybeResolveConstructorOverload(c, params, args);
			m = g.methodPlans.get(r == null ? c.constructor : r.cf);
		}
		if (m == null) return {token: 0, args: [], owner: owner};
		// A generic class's constructor is a MemberRef on the instantiation.
		var token = plan.classParams.length == 0 ? m.token : g.mb.memberRef(g.typeTokenOf(owner), ".ctor", g.sigs.method(true, LVoid, m.args, 0));
		return {token: token, args: [for (a in m.args) DotnetTypes.substitute(a, inst, [])], owner: owner};
	}

	// super(...): the base class's constructor on `this`.
	function superCtorCall(args:Array<TExpr>):Void {
		var s = cls == null ? null : cls.superClass;
		if (s == null || thisSig == null) throw new Unsupported("`super` calls", true);
		if (isExtern(s.c)) {
			code.ldarg(0);
			var ctor = externCtor(s.c, s.params, args);
			code.opToken(IlOps.CALL, ctor.token, args.length + 1, 0);
			return;
		}
		var ctor = haxeCtor(s.c, s.params, args);
		if (ctor.token == 0) throw "internal error: no constructor of " + Globals.sTypePath(s.c.path);
		code.ldarg(0);
		pushArgs(args, ctor.args);
		code.opToken(IlOps.CALL, ctor.token, args.length + 1, 0);
	}

	function construct(ret:Ret, c:TClass, params:TParams, args:Array<TExpr>):Void {
		if (isStringClass(c)) {
			// new String(s) is s.
			if (args.length != 1) throw new Unsupported("this String constructor", false);
			texpr(RValue(LString), args[0]);
			coerce(LString, ret);
			return;
		}
		if (isNativeArrayClass(c)) {
			// new NativeArray<T>(n): newarr.
			if (args.length != 1) throw "internal error: NativeArray takes one argument";
			var elem = sig(params[0]);
			texpr(RValue(LInt32), args[0]);
			code.opToken(IlOps.NEWARR, g.typeTokenOf(elem), 1, 1);
			coerce(LVector(elem), ret);
			return;
		}
		if (isExtern(c)) {
			var ctor = externCtor(c, params, args);
			code.opToken(IlOps.NEWOBJ, ctor.token, args.length, 1);
			coerce(ctor.parent, ret);
			return;
		}
		var ctor = haxeCtor(c, params, args);
		var t = ctor.owner;
		if (ctor.token == 0) {
			// A struct without a constructor that takes arguments: a zeroed value.
			if (!DotnetTypes.isValueType(t) || args.length > 0) throw "internal error: no constructor of " + Globals.sTypePath(c.path);
			var tmp = code.addLocal(t);
			code.ldloca(tmp);
			code.opToken(IlOps.INITOBJ, g.typeTokenOf(t), 1, 0);
			code.ldloc(tmp);
		} else {
			pushArgs(args, ctor.args);
			code.opToken(IlOps.NEWOBJ, ctor.token, args.length, 1);
		}
		coerce(t, ret);
	}

	static function isNativeArrayClass(c:TClass):Bool {
		return c.path.name == "NativeArray" && c.path.pack.length == 1 && c.path.pack[0] == "cs";
	}

	static function isNativeArray(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, [_]): isNativeArrayClass(c);
			case _: false;
		}
	}

	// The standard library's Array class and its type arguments, when `t` is an Array.
	static function arrayOf(t:T):Null<{c:TClass, params:TParams}> {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, params) if (c.path.pack.length == 0 && c.path.name == "Array" && !isExtern(c)): {c: c, params: params};
			case _: null;
		}
	}

	static function vectorElement(s:IlSigNorm):IlSigNorm {
		return switch (s) {
			case LVector(t): t;
			case _: throw "internal error: not a native array: " + s;
		}
	}

	// An index is an Int, or a UInt, which is the same int32 on the stack.
	function indexSig(e:TExpr):IlSigNorm {
		var s = sig(e.type);
		return isIntLike(s) ? s : LInt32;
	}

	// Array's __get or __set on an Array of type `t`.
	function arrayAccessor(t:T, name:String):{token:Int, args:Array<IlSigNorm>, ret:IlSigNorm, owner:IlSigNorm} {
		var a = arrayOf(t);
		var cf = a.c.fields.get(name);
		if (cf == null) throw new Unsupported("Array." + name, false);
		return haxeMethod(a.c, a.params, cf, [], cf.type);
	}

	// Pushes a native array and an index into it; returns the element type.
	function pushArrayAndIndex(e1:TExpr, e2:TExpr):IlSigNorm {
		var vec = sig(e1.type);
		texpr(RValue(vec), e1);
		texpr(RValue(indexSig(e2)), e2);
		return vectorElement(vec);
	}

	// a[i]: ldelem on a native array, Array's __get on an Array.
	function arrayRead(ret:Ret, e1:TExpr, e2:TExpr):Void {
		if (isNativeArray(e1.type)) {
			var elem = pushArrayAndIndex(e1, e2);
			code.opToken(IlOps.LDELEM, g.typeTokenOf(elem), 2, 1);
			coerce(elem, ret);
			return;
		}
		if (arrayOf(e1.type) == null) throw new Unsupported("array access", false);
		var m = arrayAccessor(e1.type, "__get");
		receiver(e1, m.owner);
		texpr(RValue(m.args[0]), e2);
		code.opToken(IlOps.CALLVIRT, m.token, 2, 1);
		coerce(m.ret, ret);
	}

	// [e1, e2]: a native array filled with stelem, then new Array<T>(native).
	function arrayLiteral(ret:Ret, e:TExpr, el:Array<TExpr>):Void {
		var a = arrayOf(e.type);
		if (a == null) throw new Unsupported("array literals", true);
		g.types.checkKept(TClassDecl(a.c));
		var plan = g.planOf.get(a.c);
		var elem = sig(a.params[0]);
		var owner = DotnetCtx.instanceOf(plan, [elem]);
		var ctor = null;
		for (m in plan.methods) if (m.name == ".ctor" && m.args.length == 1 && IlPaths.sigEq(m.args[0], LVector(LTypeParam(0)))) ctor = m;
		if (ctor == null) throw "internal error: Array has no constructor from a native array";
		var elemToken = g.typeTokenOf(elem);
		code.ldcI4(el.length);
		code.opToken(IlOps.NEWARR, elemToken, 1, 1);
		for (i in 0...el.length) {
			code.op(IlOps.DUP, 1, 2);
			code.ldcI4(i);
			texpr(RValue(elem), el[i]);
			code.opToken(IlOps.STELEM, elemToken, 3, 0);
		}
		code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(owner), ".ctor", g.sigs.method(true, LVoid, ctor.args, 0)), 1, 1);
		coerce(owner, ret);
	}

	// cast(e, C): castclass, unless it is an upcast.
	function checkedCast(ret:Ret, e:TExpr, e1:TExpr):Void {
		var to = sig(e.type);
		var from = sig(e1.type);
		if (!isReference(to) || to.match(LObject) || !isReference(from)) throw new Unsupported("checked casts", true);
		checkInstantiationCast(from, to);
		texpr(RValue(from), e1);
		if (!IlPaths.sigEq(from, to) && !g.isUpcast(from, to)) castTo(to);
		coerce(to, ret);
	}
}
