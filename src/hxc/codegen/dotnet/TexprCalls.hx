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
import hxc.codegen.dotnet.TexprToIl.isExtern;
import hxc.codegen.dotnet.TexprToIl.isIntLike;
import hxc.codegen.dotnet.TexprToIl.isReference;
import hxc.codegen.dotnet.TexprToIl.isStringClass;
import hxc.codegen.dotnet.TexprToIl.needVal;
import hxc.codegen.dotnet.TexprToIl.staticOwner;
import hxc.codegen.dotnet.TexprToIl.strip;
import hxc.codegen.dotnet.TexprOps.stringKind;

// The member access of TexprToIl: receivers, fields, constants, calls, constructors, arrays and casts.
// Shares its state through the TexprToIl that owns it.
@:allow(hxc.codegen.dotnet.TexprToIl, hxc.codegen.dotnet.TexprOps, hxc.codegen.dotnet.TexprFlow)
class TexprCalls {
	final tl:TexprToIl;
	final g:DotnetCtx;
	final code:IlCode;

	public function new(tl:TexprToIl) {
		this.tl = tl;
		g = tl.g;
		code = tl.code;
	}

	// The class type arguments a field access sees: a static one gets Dynamic for each.
	function instantiation(c:TClass, fa:TFieldAccess):Array<IlSigNorm> {
		return switch (fa) {
			case FInstance(_, params, _): [for (p in params) tl.sig(p)];
			case _: [for (_ in c.params) LObject];
		}
	}

	function parentOf(c:TClass, inst:Array<IlSigNorm>):IlSigNorm {
		return switch (tl.sig(TInst(c, [for (_ in c.params) TypeFunctions.tDynamic]))) {
			case LClass(p, _): LClass(p, inst);
			case LValueType(p, _): LValueType(p, inst);
			case s: s;
		}
	}

	// The object an instance member is reached through; a value type's address. A field store needs
	// the address of a variable, not of a copy.
	function receiver(obj:TExpr, parent:IlSigNorm, forStore = false):Void {
		if (!DotnetTypes.isValueType(parent)) {
			tl.texpr(RValue(parent), obj);
			return;
		}
		if (pushAddress(obj, forStore)) return;
		// A value with no home, such as a call's result: C# works on a copy too.
		if (forStore) throw new Unsupported("assignments to fields of struct values", true);
		tl.texpr(RValue(parent), obj);
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
				var s = tl.slot(v);
				if (s.arg) code.ldarga(s.index) else code.ldloca(s.index);
				return true;
			case TConst(TThis) if (tl.thisSig != null && DotnetTypes.isValueType(tl.thisSig)):
				code.ldarg(0);
				return true;
			case TField(obj, FInstance(c, cparams, cf)) if (!isExtern(c) && !isStringClass(c) && cf.kind.match(Var(_))):
				var f = instanceField(c, cparams, cf);
				receiver(obj, f.owner, forStore);
				code.opToken(IlOps.LDFLDA, f.token, 1, 1);
				return true;
			case TField(_, FStatic(c, cf)) if (!isExtern(c) && cf.kind.match(Var(_))):
				code.opToken(IlOps.LDSFLDA, tl.staticField(c, cf).token, 0, 1);
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

	// A .NET literal, typed as its field declares it: the metadata stores SByte and Byte, Int16 and
	// UInt16, Int32 and UInt32 alike, and the reader keeps the small ones unsigned.
	function constant(c:IlConstant, declared:IlSigNorm):Null<IlSigNorm> {
		switch (c) {
			case IBool(b):
				code.ldcI4(b ? 1 : 0);
				return LBool;
			case IChar(i):
				code.ldcI4(i);
				return LChar;
			case IByte(i):
				var signed = declared.match(LInt8);
				code.ldcI4(signed ? (i << 24) >> 24 : i);
				return signed ? LInt8 : LUInt8;
			case IShort(i):
				var unsigned = declared.match(LUInt16 | LChar);
				code.ldcI4(unsigned ? i : (i << 16) >> 16);
				return unsigned ? declared : LInt16;
			case IInt(i):
				code.ldcI4(i);
				return declared.match(LUInt32) ? LUInt32 : LInt32;
			case IInt64(_, i):
				code.opI64(IlOps.LDC_I8, i, 0, 1);
				return declared.match(LUInt64) ? LUInt64 : LInt64;
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
				var f = tl.staticField(c, cf);
				if (!needVal(ret)) return;
				code.opToken(IlOps.LDSFLD, f.token, 0, 1);
				tl.coerce(f.sig, ret);
			case FInstance(c, _, cf) if (isStringClass(c)):
				if (cf.name != "length") throw new Unsupported("the String field " + cf.name, false);
				tl.texpr(RValue(LString), obj);
				callString("get_Length", LInt32, []);
				tl.coerce(LInt32, ret);
			case FInstance(_, _, cf) if (cf.name == "Length" && isNativeArray(obj.type)):
				nativeLength(ret, obj);
			case FStatic(c, cf) | FInstance(c, _, cf) if (isExtern(c)):
				if (!cf.kind.match(Var(_))) throw new Unsupported("method closures", true);
				var isStatic = fa.match(FStatic(_, _));
				var inst = instantiation(c, fa);
				var parent = parentOf(c, inst);
				switch (g.externs.field(c, cf)) {
					case XConstant(k, declared):
						if (!isStatic) throw new Unsupported("instance .NET constants", true);
						var s = constant(k, declared);
						tl.coerce(s, ret);
					case XField(open, _):
						if (!isStatic) receiver(obj, parent);
						var token = g.mb.memberRef(g.typeTokenOf(parent), ExternMembers.memberName(cf), g.sigs.field(open));
						code.opToken(isStatic ? IlOps.LDSFLD : IlOps.LDFLD, token, isStatic ? 0 : 1, 1);
						tl.coerce(ExternMembers.subst(open, inst), ret);
					case XProperty(open, getter, _) if (getter != null):
						if (!isStatic) receiver(obj, parent);
						var token = g.mb.memberRef(g.typeTokenOf(parent), getter, g.sigs.method(!isStatic, open, [], 0));
						code.opToken(isStatic || DotnetTypes.isValueType(parent) ? IlOps.CALL : IlOps.CALLVIRT, token, isStatic ? 0 : 1, 1);
						tl.coerce(ExternMembers.subst(open, inst), ret);
					case _:
						throw new Unsupported("reading a write-only .NET property", false);
				}
			case FInstance(c, cparams, cf):
				if (!cf.kind.match(Var(_))) throw new Unsupported("method closures", true);
				var f = instanceField(c, cparams, cf);
				receiver(obj, f.owner);
				code.opToken(IlOps.LDFLD, f.token, 1, 1);
				tl.coerce(f.sig, ret);
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
		tl.texpr(RValue(tl.sig(obj.type)), obj);
		code.op(IlOps.LDLEN, 1, 1);
		code.op(IlOps.CONV_I4, 1, 1);
		tl.coerce(LInt32, ret);
	}

	static function isStd(c:TClass):Bool return c.path.pack.length == 0 && c.path.name == "Std";

	// The expression whose static type Std.string can print directly, else null.
	// Only an unchecked cast to Dynamic is looked through: one to another type converts or checks the
	// value, as gencs's C# cast does.
	function stringArg(e:TExpr):Null<TExpr> {
		var inner = strip(e);
		try {
			switch (inner.expr) {
				case TCast(x, null) if (tl.sig(inner.type).match(LObject)): inner = strip(x);
				case _:
			}
			stringKind(tl.sig(inner.type));
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
				tl.texpr(RValue(LString), obj);
				callString(cf.name == "toUpperCase" ? "ToUpperInvariant" : "ToLowerInvariant", LString, []);
				tl.coerce(LString, ret);
			case "toString":
				tl.texpr(RValue(LString), obj);
				tl.coerce(LString, ret);
			case "charAt" | "charCodeAt" | "indexOf" | "lastIndexOf" | "split" | "substring" | "substr":
				stringExtCall(ret, cf.name, obj, args);
			case _:
				// The private externs name the System.String member.
				var argSigs, retSig;
				switch (TypeFunctions.follow(cf.type)) {
					case TFun(fsig):
						argSigs = [for (a in fsig.args) tl.sig(a.t)];
						retSig = tl.sig(fsig.ret);
					case _:
						throw "internal error: String." + cf.name + " is not a function";
				}
				tl.texpr(RValue(LString), obj);
				pushArgs(args, argSigs);
				callString(ExternMembers.memberName(cf), retSig, argSigs);
				tl.coerce(retSig, ret);
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
		tl.coerce(found.m.ret, ret);
	}

	function pushArgs(args:Array<TExpr>, slots:Array<IlSigNorm>):Void {
		if (args.length != slots.length) throw new Unsupported("calls that leave out arguments", true);
		for (i in 0...args.length) switch (slots[i]) {
			case LManagedPointer(t):
				// cs.Ref and cs.Out: the address of a variable of exactly that type, as C#'s ref and out.
				var s = try tl.sig(args[i].type) catch (_:Unsupported) null;
				if (s == null || !IlPaths.sigEq(s, t) || !pushAddress(args[i], true))
					throw new Unsupported("by-reference arguments that are not variables of the parameter's type", true);
			case s:
				tl.texpr(RValue(s), args[i]);
		}
	}

	function call(ret:Ret, e:TExpr, callee:TExpr, args:Array<TExpr>):Void {
		switch (callee.expr) {
			case TField(_, FStatic(c, cf)) if (isStd(c) && cf.name == "int" && args.length == 1):
				// As gencs writes Std.int: a C# cast.
				tl.noDynamic(args[0], "Dynamic in Std.int");
				tl.texpr(RValue(LFloat64), args[0]);
				code.op(IlOps.CONV_I4, 1, 1);
				tl.coerce(LInt32, ret);
			case TField(_, FStatic(c, cf)) if (isStd(c) && cf.name == "string" && args.length == 1 && stringArg(args[0]) != null):
				// A value of a known type prints as in a concatenation, Bool as true or false.
				tl.ops.pushString(stringArg(args[0]));
				tl.coerce(LString, ret);
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
				tl.coerce(m.ret, ret);
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c)):
				externCall(ret, obj, fa, c, cf, args, callee.type);
			case TConst(TSuper):
				superCtorCall(args);
				tl.coerce(LVoid, ret);
			case TField(obj, FInstance(c, params, cf)):
				if (!cf.kind.match(Method(_))) throw new Unsupported("calls of function values", true);
				var m = haxeMethod(c, params, cf, args, callee.type);
				// super.m() calls the base class's method itself.
				var isSuper = strip(obj).expr.match(TConst(TSuper));
				if (isSuper) code.ldarg(0) else receiver(obj, m.owner);
				pushArgs(args, m.args);
				var op = isSuper || DotnetTypes.isValueType(m.owner) ? IlOps.CALL : IlOps.CALLVIRT;
				code.opToken(op, m.token, args.length + 1, m.ret.match(LVoid) ? 0 : 1);
				tl.coerce(m.ret, ret);
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
		var inst = [for (t in tl.ownerArgs(c, params, plan)) tl.sig(t)];
		var owner = DotnetCtx.instanceOf(plan, inst);
		return {token: g.memberOf(plan, owner, cf), sig: DotnetTypes.substitute(g.fieldSigs.get(cf), inst, []), owner: owner};
	}

	// A method's token as a call reaches it, with a MethodSpec for a generic method, and its argument
	// and return types there. `declared` is the method's type with the class's type arguments applied;
	// the call's `calleeType` gives the method's own.
	function methodRef(plan:ClassPlan, owner:IlSigNorm, inst:Array<IlSigNorm>, target:TClassField, declared:T,
			calleeType:T):{token:Int, args:Array<IlSigNorm>, ret:IlSigNorm} {
		var token = g.memberOf(plan, owner, target);
		var margs = [for (t in DotnetTypes.inferParams(target.params, declared, calleeType)) tl.sig(t)];
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
		var hxArgs = tl.ownerArgs(c, params, plan);
		var inst = [for (t in hxArgs) tl.sig(t)];
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
			margs = [for (t in DotnetTypes.inferParams(cf.params, declared, calleeType)) tl.sig(t)];
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
		tl.coerce(retSlot, ret);
	}

	// A .NET constructor: its MemberRef, with the arguments pushed.
	function externCtor(c:TClass, params:TParams, args:Array<TExpr>):{token:Int, parent:IlSigNorm} {
		var r = OverloadResolution.maybeResolveConstructorOverload(c, params, args);
		if (r == null) throw "internal error: no constructor of " + Globals.sTypePath(c.path) + " fits";
		if (r.c != c) throw new Unsupported("inherited .NET constructors", true);
		var m = g.externs.method(c, r.cf);
		var parent = ExternMembers.subst(m.parent, [for (p in params) tl.sig(p)]);
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
		var inst = [for (p in params) tl.sig(p)];
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
		var s = tl.cls == null ? null : tl.cls.superClass;
		if (s == null || tl.thisSig == null) throw new Unsupported("`super` calls", true);
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
			tl.texpr(RValue(LString), args[0]);
			tl.coerce(LString, ret);
			return;
		}
		if (isNativeArrayClass(c)) {
			// new NativeArray<T>(n): newarr.
			if (args.length != 1) throw "internal error: NativeArray takes one argument";
			var elem = tl.sig(params[0]);
			tl.texpr(RValue(LInt32), args[0]);
			code.opToken(IlOps.NEWARR, g.typeTokenOf(elem), 1, 1);
			tl.coerce(LVector(elem), ret);
			return;
		}
		if (isExtern(c)) {
			var ctor = externCtor(c, params, args);
			code.opToken(IlOps.NEWOBJ, ctor.token, args.length, 1);
			tl.coerce(ctor.parent, ret);
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
		tl.coerce(t, ret);
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
		var s = tl.sig(e.type);
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
		var vec = tl.sig(e1.type);
		tl.texpr(RValue(vec), e1);
		tl.texpr(RValue(indexSig(e2)), e2);
		return vectorElement(vec);
	}

	// a[i]: ldelem on a native array, Array's __get on an Array.
	function arrayRead(ret:Ret, e1:TExpr, e2:TExpr):Void {
		if (isNativeArray(e1.type)) {
			var elem = pushArrayAndIndex(e1, e2);
			code.opToken(IlOps.LDELEM, g.typeTokenOf(elem), 2, 1);
			tl.coerce(elem, ret);
			return;
		}
		if (arrayOf(e1.type) == null) throw new Unsupported("array access", false);
		var m = arrayAccessor(e1.type, "__get");
		receiver(e1, m.owner);
		tl.texpr(RValue(m.args[0]), e2);
		code.opToken(IlOps.CALLVIRT, m.token, 2, 1);
		tl.coerce(m.ret, ret);
	}

	// [e1, e2]: a native array filled with stelem, then new Array<T>(native).
	function arrayLiteral(ret:Ret, e:TExpr, el:Array<TExpr>):Void {
		var a = arrayOf(e.type);
		if (a == null) throw new Unsupported("array literals", true);
		g.types.checkKept(TClassDecl(a.c));
		var plan = g.planOf.get(a.c);
		var elem = tl.sig(a.params[0]);
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
			tl.texpr(RValue(elem), el[i]);
			code.opToken(IlOps.STELEM, elemToken, 3, 0);
		}
		code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(owner), ".ctor", g.sigs.method(true, LVoid, ctor.args, 0)), 1, 1);
		tl.coerce(owner, ret);
	}

	// cast(e, C): castclass, unless it is an upcast.
	function checkedCast(ret:Ret, e:TExpr, e1:TExpr):Void {
		var to = tl.sig(e.type);
		var from = tl.sig(e1.type);
		if (!isReference(to) || to.match(LObject) || !isReference(from)) throw new Unsupported("checked casts", true);
		tl.checkInstantiationCast(from, to);
		tl.texpr(RValue(from), e1);
		if (!IlPaths.sigEq(from, to) && !g.isUpcast(from, to)) tl.castTo(to);
		tl.coerce(to, ret);
	}
}
