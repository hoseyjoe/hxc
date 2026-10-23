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
import hxc.codegen.dotnet.TexprCalls.arrayOf;
import hxc.codegen.dotnet.TexprCalls.isNativeArray;
import hxc.codegen.dotnet.TexprCalls.vectorElement;

// Where an expression's value goes: onto the stack as a slot of the given type (null: its own),
// nowhere, or out of the function (a function body, whose value is not used).
enum Ret {
	RValue(t:Null<IlSigNorm>);
	RVoid;
	RReturn;
}

// A local or argument slot.
typedef Slot = {arg:Bool, index:Int, sig:IlSigNorm};

// Something that can be loaded and stored. `prepare` pushes the receiver, if there is one; `load` keeps
// it under the value and `store` takes both.
typedef Place = {sig:IlSigNorm, receiver:Bool, prepare:Void->Void, load:Void->Void, store:Void->Void};

// How an operand is treated when operands are spilled before a try: evaluated into a temporary, left
// where it is, or refused.
enum SpillMode {
	Spill;
	Keep;
	Refuse;
}

// One method body's expressions as IL. Anything outside the subset this milestone compiles throws
// Unsupported naming it.

@:allow(hxc.codegen.dotnet.TexprOps, hxc.codegen.dotnet.TexprFlow, hxc.codegen.dotnet.TexprCalls)
class TexprToIl {
	final g:DotnetCtx;
	final code:IlCode;
	final ret:IlSigNorm;
	final slots = new Map<Int, Slot>();
	// Variables whose declaration failed to lower; a failing statement that uses one is not reported
	// again.
	final poisoned = new Map<Int, Bool>();
	// Where break and continue go, innermost loop last, with the try depth each loop was entered at.
	final loops:Array<{brk:Label, cont:Label, tries:Int}> = [];
	// How many try blocks and handlers enclose the code being lowered. A jump out of one is a `leave`.
	var tryDepth = 0;
	// Where a `return` inside a try goes: a label after the outermost try, which returns the value
	// stored in `retLocal` (-1 until needed).
	var retLabel:Label = -1;
	var retLocal = -1;
	// Temporaries that operands were spilled to; they are never spilled again.
	final temps = new Map<Int, Bool>();

	// The rest of the lowering, which reaches this class's state through it.
	final ops:TexprOps;
	final flow:TexprFlow;
	final calls:TexprCalls;

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
		ops = new TexprOps(this);
		flow = new TexprFlow(this);
		calls = new TexprCalls(this);
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

	// The type of a value of type `t`. A cs.Ref or cs.Out is a parameter's own type only: a variable or
	// value of that type, such as `var node = head` for a cs.Ref parameter `head`, has the referenced type,
	// as in C#.
	function sig(t:T):IlSigNorm {
		return switch (g.types.toSig(t)) {
			case LManagedPointer(s): s;
			case s: s;
		}
	}

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
		// So is a smaller integer, widened as C# does implicitly.
		if (from.match(LChar | LInt8 | LUInt8 | LInt16 | LUInt16) && to.match(LInt32)) return;
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
		var s = anySlot(v);
		if (s.sig.match(LManagedPointer(_))) throw new Unsupported("cs.Ref and cs.Out parameters", true);
		return s;
	}

	// The slot of a variable, a cs.Ref or cs.Out parameter's too.
	function anySlot(v:TVar):Slot {
		var s = slots.get(v.id);
		// The statement using it is not reported again: the declaration already was.
		if (s == null && poisoned.exists(v.id)) throw new Unsupported("a variable whose declaration failed", false);
		if (s == null) throw "internal error: unbound variable " + v.name;
		return s;
	}

	// The type of the variable a cs.Ref or cs.Out parameter's slot holds the address of, else null.
	static function refTarget(s:Slot):Null<IlSigNorm> {
		return switch (s.sig) {
			case LManagedPointer(t): t;
			case _: null;
		}
	}

	// Through the address on the stack, as C# reads and writes a ref parameter.
	function loadIndirect(t:IlSigNorm):Void {
		if (DotnetTypes.isValueType(t) || isTypeParam(t)) code.opToken(IlOps.LDOBJ, g.typeTokenOf(t), 1, 1) else code.op(IlOps.LDIND_REF, 1, 1);
	}

	function storeIndirect(t:IlSigNorm):Void {
		if (DotnetTypes.isValueType(t) || isTypeParam(t)) code.opToken(IlOps.STOBJ, g.typeTokenOf(t), 2, 0) else code.op(IlOps.STIND_REF, 2, 0);
	}

	// The prefix a load or store of a @:volatile field takes, as C# compiles a volatile field's.
	function volatilePrefix(cf:TClassField):Void {
		if (TypeFunctions.hasMeta(":volatile", cf.meta)) code.op(IlOps.VOLATILE, 0, 0);
	}

	function load(s:Slot):Void {
		if (s.arg) code.ldarg(s.index) else code.ldloc(s.index);
	}

	function store(s:Slot):Void {
		if (s.arg) code.starg(s.index) else code.stloc(s.index);
	}

	function expr(ret:Ret, e:TExpr):Void {
		var spilled = flow.spillForTry(e);
		if (spilled != null) {
			expr(ret, spilled);
			return;
		}
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
				var s = anySlot(v);
				var target = refTarget(s);
				load(s);
				if (target != null) loadIndirect(target);
				coerce(target != null ? target : s.sig, ret);
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
				flow.exitMethod(false);
			case TReturn(e1):
				if (code.depth != 0) throw new Unsupported("`return` inside expressions", false);
				if (this.ret.match(LVoid)) {
					// `return f()` with a Void f.
					texpr(RVoid, e1);
					if (code.reachable()) flow.exitMethod(false);
				} else {
					texpr(RValue(this.ret), e1);
					if (code.reachable()) flow.exitMethod(true);
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
				ops.compound(ret, op, lhs, rhs);
			case TBinop(op, e1, e2):
				ops.binary(ret, e, op, e1, e2);
			case TUnop(op, flag, e1):
				ops.unary(ret, e, op, flag, e1);
			case TIf(cond, eif, eelse):
				flow.ifExpr(ret, e, cond, eif, eelse);
			case TWhile(cond, body, flag):
				flow.whileLoop(ret, cond, body, flag);
			case TSwitch(subject, cases, def):
				flow.switchExpr(ret, e, subject, cases, def);
			case TBreak:
				if (loops.length == 0) throw new Unsupported("`break` outside a loop", false);
				// The loop's labels are reached with an empty stack.
				if (code.depth != 0) throw new Unsupported("`break` inside expressions", false);
				var loop = loops[loops.length - 1];
				code.branch(tryDepth > loop.tries ? IlOps.LEAVE : IlOps.BR, loop.brk);
			case TContinue:
				if (loops.length == 0) throw new Unsupported("`continue` outside a loop", false);
				if (code.depth != 0) throw new Unsupported("`continue` inside expressions", false);
				var loop = loops[loops.length - 1];
				code.branch(tryDepth > loop.tries ? IlOps.LEAVE : IlOps.BR, loop.cont);
			case TField(obj, fa):
				calls.fieldRead(ret, e, obj, fa);
			case TCall(callee, args):
				calls.call(ret, e, callee, args);
			case TNew(c, params, args):
				calls.construct(ret, c, params, args);
			case TFunction(_):
				throw new Unsupported("local functions", true);
			case TTypeExpr(_):
				throw new Unsupported("type expressions", true);
			case TArray(e1, e2):
				calls.arrayRead(ret, e1, e2);
			case TObjectDecl(_):
				throw new Unsupported("anonymous objects", true);
			case TArrayDecl(el):
				calls.arrayLiteral(ret, e, el);
			case TFor(_, _, _):
				throw new Unsupported("for loops", true);
			case TTry(body, catches):
				flow.tryExpr(ret, e, body, catches);
			case TThrow(e1):
				flow.throwExpr(e1);
			case TCast(e1, TClassDecl(_)):
				calls.checkedCast(ret, e, e1);
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
			// The statement giving the block's value fails with the statement around the block: the code
			// after it expects the value on the stack.
			if (onError == null || needVal(r)) {
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
			case TLocal(v) if (refTarget(anySlot(v)) != null):
				var s = anySlot(v);
				var target = refTarget(s);
				load(s);
				texpr(RValue(target), rhs);
				var tmp = needVal(ret) ? ops.keepTop(target) : -1;
				storeIndirect(target);
				if (tmp >= 0) {
					code.ldloc(tmp);
					coerce(target, ret);
				}
			case TLocal(v):
				var s = slot(v);
				texpr(RValue(s.sig), rhs);
				if (needVal(ret)) code.op(IlOps.DUP, 1, 2);
				store(s);
				if (needVal(ret)) coerce(s.sig, ret);
			case TArray(e1, e2) if (isNativeArray(e1.type)):
				var elem = calls.pushArrayAndIndex(e1, e2);
				texpr(RValue(elem), rhs);
				var tmp = needVal(ret) ? ops.keepTop(elem) : -1;
				code.opToken(IlOps.STELEM, g.typeTokenOf(elem), 3, 0);
				if (tmp >= 0) {
					code.ldloc(tmp);
					coerce(elem, ret);
				}
			case TArray(e1, e2) if (arrayOf(e1.type) != null):
				var m = calls.arrayAccessor(e1.type, "__set");
				calls.receiver(e1, m.owner);
				texpr(RValue(m.args[0]), e2);
				texpr(RValue(m.args[1]), rhs);
				code.opToken(IlOps.CALLVIRT, m.token, 3, 1);
				// __set returns the value it stored.
				coerce(m.ret, ret);
			case TField(_, FStatic(c, cf)) if (!isExtern(c)):
				var f = staticField(c, cf);
				texpr(RValue(f.sig), rhs);
				if (needVal(ret)) code.op(IlOps.DUP, 1, 2);
				volatilePrefix(cf);
				code.opToken(IlOps.STSFLD, f.token, 1, 0);
				if (needVal(ret)) coerce(f.sig, ret);
			case TField(obj, FInstance(c, cparams, cf)) if (!isExtern(c) && !isStringClass(c)):
				var f = calls.instanceField(c, cparams, cf);
				calls.receiver(obj, f.owner, true);
				texpr(RValue(f.sig), rhs);
				var tmp = needVal(ret) ? ops.keepTop(f.sig) : -1;
				volatilePrefix(cf);
				code.opToken(IlOps.STFLD, f.token, 2, 0);
				if (tmp >= 0) {
					code.ldloc(tmp);
					coerce(f.sig, ret);
				}
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c)):
				var isStatic = fa.match(FStatic(_, _));
				var inst = calls.instantiation(c, fa);
				var parent = calls.parentOf(c, inst);
				switch (g.externs.field(c, cf)) {
					case XField(open, initOnly):
						var s = ExternMembers.subst(open, inst);
						if (initOnly) throw new Unsupported("assignments to read-only .NET fields", true);
						if (needVal(ret)) throw new Unsupported("the value of an assignment to a .NET field", false);
						if (!isStatic) calls.receiver(obj, parent);
						texpr(RValue(s), rhs);
						var token = g.mb.memberRef(g.typeTokenOf(parent), ExternMembers.memberName(cf), g.sigs.field(open));
						code.opToken(isStatic ? IlOps.STSFLD : IlOps.STFLD, token, isStatic ? 1 : 2, 0);
					case XProperty(open, _, setter) if (setter != null):
						var s = ExternMembers.subst(open, inst);
						if (needVal(ret)) throw new Unsupported("the value of an assignment to a .NET property", false);
						if (!isStatic) calls.receiver(obj, parent);
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

	// A local or a Haxe class's static variable, which can be loaded and stored without a receiver; an
	// instance variable; an array element, whose array and index are kept in temporaries.
	function place(e:TExpr):Null<Place> {
		switch (e.expr) {
			case TParenthesis(e1) | TMeta(_, e1):
				return place(e1);
			case TArray(e1, e2) if (isNativeArray(e1.type) || arrayOf(e1.type) != null):
				var native = isNativeArray(e1.type);
				var get = native ? null : calls.arrayAccessor(e1.type, "__get");
				var set = native ? null : calls.arrayAccessor(e1.type, "__set");
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
						var idxSig = native ? calls.indexSig(e2) : get.args[0];
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
			case TLocal(v) if (refTarget(anySlot(v)) != null):
				var s = anySlot(v);
				var target = refTarget(s);
				return {
					sig: target,
					receiver: true,
					prepare: () -> load(s),
					load: () -> {
						code.op(IlOps.DUP, 1, 2);
						loadIndirect(target);
					},
					store: () -> storeIndirect(target)
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
					load: () -> {
						volatilePrefix(cf);
						code.opToken(IlOps.LDSFLD, f.token, 0, 1);
					},
					store: () -> {
						volatilePrefix(cf);
						code.opToken(IlOps.STSFLD, f.token, 1, 0);
					}
				};
			case TField(obj, FInstance(c, cparams, cf)) if (!isExtern(c) && !isStringClass(c) && cf.kind.match(Var(_))):
				var f = calls.instanceField(c, cparams, cf);
				return {
					sig: f.sig,
					receiver: true,
					prepare: () -> calls.receiver(obj, f.owner, true),
					load: () -> {
						code.op(IlOps.DUP, 1, 2);
						volatilePrefix(cf);
						code.opToken(IlOps.LDFLD, f.token, 1, 1);
					},
					store: () -> {
						volatilePrefix(cf);
						code.opToken(IlOps.STFLD, f.token, 2, 0);
					}
				};
			case _:
				return null;
		}
	}
}
