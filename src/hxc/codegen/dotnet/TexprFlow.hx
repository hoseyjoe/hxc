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
import hxc.codegen.dotnet.TexprToIl.needVal;
import hxc.codegen.dotnet.TexprToIl.strip;

// The control flow of TexprToIl: if, while, switch, return, throw and try, and the spilling of operands
// that a try would otherwise discard. Shares its state through the TexprToIl that owns it.
@:allow(hxc.codegen.dotnet.TexprToIl, hxc.codegen.dotnet.TexprOps, hxc.codegen.dotnet.TexprCalls, hxc.codegen.dotnet.TexprDynamic)
class TexprFlow {
	final tl:TexprToIl;
	final g:DotnetCtx;
	final code:IlCode;

	public function new(tl:TexprToIl) {
		this.tl = tl;
		g = tl.g;
		code = tl.code;
	}

	// The type of a value `if` or `switch`: the surrounding one, else its own.
	function valueRet(ret:Ret, e:TExpr):Ret {
		return switch (ret) {
			case RValue(null):
				var t = tl.sig(e.type);
				t.match(LVoid) ? ret : RValue(t);
			case _: ret;
		}
	}

	function ifExpr(ret:Ret, e:TExpr, cond:TExpr, eif:TExpr, eelse:Null<TExpr>):Void {
		if (eelse == null && needVal(ret)) throw new Unsupported("Void values", true);
		var r = valueRet(ret, e);
		var other = code.newLabel();
		tl.ops.jumpIf(cond, other, false);
		tl.texpr(r, eif);
		if (eelse == null) {
			code.markIfUsed(other);
			return;
		}
		var end = code.newLabel();
		if (code.reachable()) code.branch(IlOps.BR, end);
		code.markIfUsed(other);
		tl.texpr(r, eelse);
		code.markIfUsed(end);
	}

	function whileLoop(ret:Ret, cond:TExpr, body:TExpr, flag:WhileFlag):Void {
		// A loop head is a backward branch target, which needs an empty stack.
		if (code.depth != 0) throw new Unsupported("loops inside expressions", true);
		var top = code.newLabel(), cont = code.newLabel(), brk = code.newLabel();
		code.mark(top);
		var isDo = flag.match(DoWhile);
		tl.loops.push({brk: brk, cont: isDo ? cont : top, tries: tl.tryDepth});
		try {
			if (isDo) {
				tl.texpr(RVoid, body);
				code.markIfUsed(cont);
				tl.ops.jumpIf(cond, top, true);
			} else {
				tl.ops.jumpIf(cond, brk, false);
				tl.texpr(RVoid, body);
				if (code.reachable()) code.branch(IlOps.BR, top);
			}
		} catch (x:Dynamic) {
			tl.loops.pop();
			throw x;
		}
		tl.loops.pop();
		code.markIfUsed(brk);
		tl.coerce(LVoid, ret);
	}

	// A chain of comparisons in case order, then the default.
	function switchExpr(ret:Ret, e:TExpr, subject:TExpr, cases:Array<TSwitchCase>, def:Null<TExpr>):Void {
		if (def == null && needVal(ret)) throw new Unsupported("switch expressions without a default", true);
		var r = valueRet(ret, e);
		if (def == null && isExhaustive(subject)) tl.exhaustiveSwitch = true;
		// A switch on enumIndex(x) of a .NET enum is one on x, against the constructors' values.
		var ext = TexprToIl.externEnumIndex(subject);
		if (ext != null) subject = ext.value;
		// A Null<T> subject switches on its value, as HardNullableSynf unwraps it.
		var own = tl.sig(subject.type);
		var st = tl.unNull(own);
		var isString = st.match(LString);
		if (ext == null && !isString && !st.match(LInt32 | LBool)) throw new Unsupported("switch on this type", false);
		var local:Null<Slot> = null;
		switch (strip(subject).expr) {
			case TLocal(v) if (!tl.isHaxeNull(own)): local = tl.slot(v);
			case _:
		}
		var tmp = -1;
		if (local == null) {
			tl.texpr(RValue(st), subject);
			tmp = code.addLocal(st);
			code.stloc(tmp);
		}
		var bodies = [for (_ in cases) code.newLabel()];
		var eq = isString ? g.mb.memberRef(g.typeTokenOf(LString), "op_Equality", g.sigs.method(false, LBool, [LString, LString], 0)) : 0;
		for (i in 0...cases.length) for (v in cases[i].values) {
			if (local != null) tl.load(local) else code.ldloc(tmp);
			if (ext != null) {
				var i = TexprToIl.constInt(v);
				if (i == null) throw new Unsupported("switch on this type", false);
				tl.calls.externEnumLiteral(ext.en, TexprToIl.enumFieldAt(ext.en, i));
			} else {
				tl.texpr(RValue(st), v);
			}
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
			tl.texpr(r, cases[i].expr);
			if (code.reachable()) code.branch(IlOps.BR, end);
		}
		if (def != null) {
			code.mark(defLabel);
			tl.texpr(r, def);
		}
		code.markIfUsed(end);
	}

	static function isExhaustive(e:TExpr):Bool {
		return switch (e.expr) {
			case TMeta({name: ":exhaustive"}, _): true;
			case TParenthesis(e1) | TMeta(_, e1): isExhaustive(e1);
			case _: false;
		}
	}

	// `return`: a `ret`, or inside a try a store to the return local and a `leave` to the label after
	// the outermost try, which returns it.
	function exitMethod(withValue:Bool):Void {
		if (tl.tryDepth == 0) {
			code.op(IlOps.RET, withValue ? 1 : 0, 0);
			return;
		}
		if (withValue) {
			if (tl.retLocal < 0) tl.retLocal = code.addLocal(tl.ret);
			code.stloc(tl.retLocal);
		}
		if (tl.retLabel < 0) tl.retLabel = code.newLabel();
		code.branch(IlOps.LEAVE, tl.retLabel);
	}

	static final systemException:IlSigNorm = LClass({ns: ["System"], nested: [], name: "Exception"}, []);

	// The exceptions filter has already wrapped values that are not .NET exceptions.
	function throwExpr(e1:TExpr):Void {
		var s = tl.sig(e1.type);
		if (!s.match(LObject | LClass(_, _))) throw new Unsupported("throw of " + hxc.core.TPrinting.sTypeStr(e1.type), false);
		tl.texpr(RValue(s), e1);
		if (!code.reachable()) return;
		// Dynamic, such as haxe.Exception.thrown's result, is cast as C# casts a thrown value.
		if (s.match(LObject)) tl.castTo(systemException);
		code.op(IlOps.THROW, 1, 0);
	}

	// The type a catch clause catches: a class, as the exceptions filter leaves only native types here.
	function catchClass(v:TVar):IlSigNorm {
		var s = tl.sig(v.type);
		if (!s.match(LClass(_, _))) throw new Unsupported("catch of " + hxc.core.TPrinting.sTypeStr(v.type), false);
		return s;
	}

	// A protected region with a typed clause per catch, in order. Each part leaves to the end with its
	// value, if the try has one, in a temporary.
	function tryExpr(ret:Ret, e:TExpr, body:TExpr, catches:Array<TCatch>):Void {
		// Operands before a try are spilled (spillForTry); this is a position that does not spill.
		if (code.depth != 0) throw new Unsupported("`try` inside this expression", false);
		var r = valueRet(ret, e);
		var t = switch (r) {
			case RValue(s): s;
			case _: null;
		}
		var inner = t == null ? RVoid : r;
		var classes = [for (c in catches) catchClass(c.v)];
		var result = t == null ? -1 : code.addLocal(t);
		var end = code.newLabel();
		function leave() {
			if (!code.reachable()) return;
			if (result >= 0) code.stloc(result);
			code.branch(IlOps.LEAVE, end);
		}
		var outermost = tl.tryDepth == 0;
		var open = code.openTries;
		tl.tryDepth++;
		try {
			code.beginTry();
			tl.texpr(inner, body);
			leave();
			for (i in 0...catches.length) {
				// The handler starts with the exception on the stack.
				code.beginCatch(g.typeTokenOf(classes[i]));
				var local = {arg: false, index: code.addLocal(classes[i]), sig: classes[i]};
				tl.store(local);
				tl.slots.set(catches[i].v.id, local);
				tl.texpr(inner, catches[i].expr);
				leave();
			}
			code.endTry();
		} catch (x:Dynamic) {
			tl.tryDepth--;
			code.abandonTries(open);
			if (outermost) tl.retLabel = -1;
			throw x;
		}
		tl.tryDepth--;
		if (outermost) returnAfterTry();
		code.markIfUsed(end);
		if (t == null) tl.coerce(LVoid, ret) else if (code.reachable()) {
			code.ldloc(result);
			tl.coerce(t, ret);
		}
	}

	// After the outermost try: the label a `return` inside it leaves to, which returns the value it
	// stored.
	function returnAfterTry():Void {
		if (tl.retLabel < 0) return;
		code.markIfUsed(tl.retLabel);
		if (code.reachable()) {
			if (tl.ret.match(LVoid)) {
				code.op(IlOps.RET, 0, 0);
			} else {
				code.ldloc(tl.retLocal);
				code.op(IlOps.RET, 1, 0);
			}
		}
		tl.retLabel = -1;
	}

	// A protected region with a finally handler, in statement position: `body` lowers the block, which
	// leaves to the end, and `fin` the handler, which ends with endfinally. A jump out of the block is a
	// `leave`, which runs the handler.
	function tryFinally(body:() -> Void, fin:() -> Void):Void {
		if (code.depth != 0) throw "internal error: a try/finally entered with a non-empty stack";
		var end = code.newLabel();
		var outermost = tl.tryDepth == 0;
		var open = code.openTries;
		tl.tryDepth++;
		try {
			code.beginTry();
			body();
			if (code.reachable()) code.branch(IlOps.LEAVE, end);
			code.beginFinally();
			fin();
			code.op(IlOps.ENDFINALLY, 0, 0);
			code.endTry();
		} catch (x:Dynamic) {
			tl.tryDepth--;
			code.abandonTries(open);
			if (outermost) tl.retLabel = -1;
			throw x;
		}
		tl.tryDepth--;
		if (outermost) returnAfterTry();
		code.markIfUsed(end);
	}

	static function containsTry(e:TExpr):Bool {
		return switch (e.expr) {
			case TTry(_, _): true;
			case TFunction(_): false;
			case _: TexprTools.checkExpr(containsTry, e);
		}
	}

	// A try block starts on an empty stack. When one is in an operand pushed after another value, that
	// operand and the ones before it are evaluated into temporaries first, left to right, and the
	// expression is lowered over reads of them. Null when nothing needs that.
	function spillForTry(e:TExpr):Null<TExpr> {
		function with(x:TExprExpr):TExpr return new TExpr(x, e.type, e.pos);
		switch (e.expr) {
			case TBinop(OpAssign, lhs, rhs):
				var parts = placeParts(lhs);
				if (parts == null) return null;
				var ops = spillOperands(parts.ops.concat([rhs]), parts.modes.concat([Spill]), false);
				if (ops == null) return null;
				return with(TBinop(OpAssign, parts.rebuild(ops), ops[ops.length - 1]));
			case TBinop(OpAssignOp(op), lhs, rhs) if (containsTry(rhs)):
				// The place's parts, then its value combined with the right side, then the store.
				var parts = placeParts(lhs);
				var target = lhs;
				if (parts != null) {
					var ops = spillOperands(parts.ops, parts.modes, true);
					if (ops != null) target = parts.rebuild(ops);
				}
				var value = spill(new TExpr(TBinop(op, target, rhs), lhs.type, e.pos));
				return with(TBinop(OpAssign, target, value));
			case TBinop(OpBoolAnd | OpBoolOr | OpAssignOp(_), _, _):
				// The right side of && and || is reached by a branch, with nothing on the stack.
				return null;
			case TBinop(op, e1, e2):
				var ops = spillOperands([e1, e2], [Spill, Spill], false);
				return ops == null ? null : with(TBinop(op, ops[0], ops[1]));
			case TArray(e1, e2):
				var ops = spillOperands([e1, e2], [Spill, Spill], false);
				return ops == null ? null : with(TArray(ops[0], ops[1]));
			case TArrayDecl(el):
				// The new array, a copy and an index are under each element.
				var ops = spillOperands(el, [for (_ in el) Spill], true);
				return ops == null ? null : with(TArrayDecl(ops));
			case TNew(c, params, args):
				if (!Lambda.exists(args, containsTry)) return null;
				var ctorType = c.constructor == null ? null : c.constructor.type;
				var ops = spillOperands(args, argModes(ctorType, args), false);
				return ops == null ? null : with(TNew(c, params, ops));
			case TCall(callee, args):
				// A try in the receiver alone is evaluated first.
				if (!Lambda.exists(args, containsTry)) return null;
				var modes = argModes(callee.type, args);
				switch (callee.expr) {
					case TConst(TSuper):
						// `this` is under the arguments.
						var ops = spillOperands(args, modes, true);
						return ops == null ? null : with(TCall(callee, ops));
					case TField(obj, fa = FInstance(_, _, _)):
						if (strip(obj).expr.match(TConst(TSuper))) {
							var ops = spillOperands(args, modes, true);
							return ops == null ? null : with(TCall(callee, ops));
						}
						var ops = spillOperands([obj].concat(args), [receiverMode(obj)].concat(modes), false);
						if (ops == null) return null;
						return with(TCall(new TExpr(TField(ops[0], fa), callee.type, callee.pos), ops.slice(1)));
					case _:
						var ops = spillOperands(args, modes, false);
						return ops == null ? null : with(TCall(callee, ops));
				}
			case _:
				return null;
		}
	}

	// The operands an assignment's target pushes before the value, and the target over new ones; null
	// for a target that pushes nothing.
	function placeParts(lhs:TExpr):Null<{ops:Array<TExpr>, modes:Array<SpillMode>, rebuild:Array<TExpr>->TExpr}> {
		var e = strip(lhs);
		return switch (e.expr) {
			case TArray(e1, e2):
				{ops: [e1, e2], modes: [Spill, Spill], rebuild: ops -> new TExpr(TArray(ops[0], ops[1]), e.type, e.pos)};
			case TField(obj, fa = FInstance(_, _, _)):
				{ops: [obj], modes: [receiverMode(obj)], rebuild: ops -> new TExpr(TField(ops[0], fa), e.type, e.pos)};
			case _:
				null;
		}
	}

	// A struct receiver is used through its address, which is not kept in a temporary: a local's, or a
	// field's of a struct local, stays where it is, as the operands cannot change it; one reached
	// through an object is refused; a value with no home is copied, as it would be anyway.
	function receiverMode(obj:TExpr):SpillMode {
		if (!isStruct(obj)) return Spill;
		if (fixedAddress(obj)) return Keep;
		return strip(obj).expr.match(TField(_, _)) ? Refuse : Spill;
	}

	function isStruct(e:TExpr):Bool {
		var s = try tl.sig(e.type) catch (_:Unsupported) null;
		return s != null && DotnetTypes.isValueType(s);
	}

	function fixedAddress(e:TExpr):Bool {
		return switch (strip(e).expr) {
			case TLocal(_) | TConst(_): true;
			case TField(obj, FInstance(_, _, _)) if (isStruct(obj)): fixedAddress(obj);
			case _: false;
		}
	}

	// A cs.Ref or cs.Out argument is a variable's address, which stays where it is.
	static function argModes(fnType:Null<T>, args:Array<TExpr>):Array<SpillMode> {
		var fargs = fnType == null ? [] : switch (TypeFunctions.follow(fnType)) {
			case TFun(fsig): fsig.args;
			case _: [];
		}
		return [
			for (i in 0...args.length) {
				var byRef = i < fargs.length && switch (fargs[i].t) {
					case TType(d, _): d.path.pack.length == 1 && d.path.pack[0] == "cs" && (d.path.name == "Ref" || d.path.name == "Out");
					case _: false;
				}
				byRef ? Keep : Spill;
			}
		];
	}

	// The operands up to the last one with a try, spilled; null when that is the first value pushed.
	function spillOperands(ops:Array<TExpr>, modes:Array<SpillMode>, pushedBefore:Bool):Null<Array<TExpr>> {
		// From the end, so the first operand of an expression that pushes nothing before it is not
		// searched: a chain of binary operators is searched once.
		var last = ops.length - 1;
		var first = pushedBefore ? 0 : 1;
		while (last >= first && !containsTry(ops[last])) last--;
		if (last < first) return null;
		for (i in 0...last + 1) if (modes[i] == Refuse) throw new Unsupported("`try` in an operand after a member of a struct field", false);
		return [for (i in 0...ops.length) i <= last && modes[i] == Spill ? spill(ops[i]) : ops[i]];
	}

	// Evaluates `e` into a new temporary and returns a read of it. Constants and temporaries stay.
	function spill(e:TExpr):TExpr {
		switch (strip(e).expr) {
			case TConst(TInt(_) | TFloat(_) | TString(_) | TBool(_) | TNull | TSuper):
				return e;
			case TConst(TThis) if (tl.thisSig != null && !DotnetTypes.isValueType(tl.thisSig)):
				return e;
			case TLocal(v) if (tl.temps.exists(v.id)):
				return e;
			case _:
		}
		var s = tl.sig(e.type);
		tl.texpr(RValue(s), e);
		var v = TypeFunctions.allocVar(VGenerated, "tmp", e.type, e.pos);
		var local = {arg: false, index: code.addLocal(s), sig: s};
		if (code.reachable()) tl.store(local);
		tl.slots.set(v.id, local);
		tl.temps.set(v.id, true);
		return new TExpr(TLocal(v), e.type, e.pos);
	}
}
