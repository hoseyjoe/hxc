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
import hxc.codegen.dotnet.TclassToIl.MethodKind;
import hxc.codegen.dotnet.TclassToIl.MethodPlan;
import hxc.codegen.dotnet.TexprToIl.Place;
import hxc.codegen.dotnet.TexprToIl.Ret;
import hxc.codegen.dotnet.TexprToIl.Slot;
import hxc.codegen.dotnet.TexprToIl.SpillMode;
import hxc.codegen.dotnet.TexprToIl.isExtern;
import hxc.codegen.dotnet.TexprToIl.isIntLike;
import hxc.codegen.dotnet.TexprToIl.isReference;
import hxc.codegen.dotnet.TexprToIl.isStringClass;
import hxc.codegen.dotnet.TexprToIl.isTypeParam;
import hxc.codegen.dotnet.TexprToIl.refTarget;
import hxc.codegen.dotnet.TexprToIl.needVal;
import hxc.codegen.dotnet.TexprToIl.staticOwner;
import hxc.codegen.dotnet.TexprToIl.strip;
import hxc.codegen.dotnet.TexprOps.stringKind;

// The member access of TexprToIl: receivers, fields, constants, calls, constructors, arrays and casts.
// Shares its state through the TexprToIl that owns it.
@:allow(hxc.codegen.dotnet.TexprToIl, hxc.codegen.dotnet.TexprOps, hxc.codegen.dotnet.TexprFlow, hxc.codegen.dotnet.TexprDynamic)
class TexprCalls {
	final tl:TexprToIl;
	final g:DotnetCtx;
	final code:IlCode;
	// A call of a function value that an unsafe cast to Dynamic wraps (TexprToIl.castExpr): its `_f`
	// result goes boxed as the double, without the conversion to the call's type.
	var rawCall:Null<TExpr> = null;

	public function new(tl:TexprToIl) {
		this.tl = tl;
		g = tl.g;
		code = tl.code;
	}

	// The class type arguments a field access sees: a static one gets Dynamic for each.
	function instantiation(c:TClass, fa:TFieldAccess):Array<IlSigNorm> {
		return switch (fa) {
			case FInstance(_, params, _): g.types.classArgs(c, params);
			case _: [for (_ in c.params) LObject];
		}
	}

	function parentOf(c:TClass, inst:Array<IlSigNorm>):IlSigNorm {
		return switch (g.types.classSig(c, [for (_ in c.params) TypeFunctions.tDynamic])) {
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
		// A member of a Null<T>'s T is reached through a copy of its value, as HardNullableSynf unwraps it.
		var own = try tl.sig(obj.type) catch (_:Unsupported) null;
		var unwraps = own != null && tl.isHaxeNull(own) && !IlPaths.sigEq(own, parent);
		if (!unwraps && pushAddress(obj, forStore)) return;
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
			case TLocal(v) if (refTarget(tl.anySlot(v)) != null):
				// A cs.Ref or cs.Out parameter holds the address already.
				tl.load(tl.anySlot(v));
				return true;
			case TLocal(v):
				var s = tl.slot(v);
				if (s.arg) code.ldarga(s.index) else code.ldloca(s.index);
				return true;
			case TConst(TThis) if (tl.thisSig != null && DotnetTypes.isValueType(tl.thisSig)):
				code.ldarg(0);
				return true;
			case TField(obj, fa = FInstance(c, cparams, cf)) if (!isExtern(c) && !isStringClass(c) && cf.kind.match(Var(_))
				&& !tl.dyn.isDynamicReceiver(fa, obj)):
				var f = instanceField(c, cparams, cf);
				receiver(obj, f.owner, forStore);
				code.opToken(IlOps.LDFLDA, f.token, 1, 1);
				return true;
			case TField(_, FStatic(c, cf)) if (!isExtern(c) && cf.kind.match(Var(_))):
				code.opToken(IlOps.LDSFLDA, tl.staticField(c, cf).token, 0, 1);
				return true;
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c) && cf.kind.match(Var(_))):
				switch (g.externs.field(c, cf, true, true)) {
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
			case FClosure(null, cf):
				// A method of an anonymous structure is one of its fields.
				if (!TexprDynamic.isDynamic(obj.type)) throw new Unsupported("method closures", true);
				tl.dyn.fieldGet(ret, e, obj, cf.name, e.type, true);
			case FInstance(_, _, cf) | FClosure(_, cf) if (tl.dyn.isDynamicReceiver(fa, obj)):
				// A variable or dynamic method of a Haxe interface, or a member of a value typed as a companion
				// interface that the companion lacks, through Runtime.getField as gencs reads it.
				tl.dyn.fieldGet(ret, e, obj, cf.name, e.type, true);
			case FStatic(c, cf) if (!isExtern(c) && isMethod(cf)):
				// A static method as a value: `new Closure(typeof(C), "name", hash)`.
				g.types.checkKept(TClassDecl(c));
				var plan = g.ownerOf.get(cf);
				if (plan == null) throw Unsupported.bug("a closure of " + Globals.sTypePath(c.path) + "." + cf.name + " without a method (an hxc bug)");
				pushClosure(null, staticOwner(plan), cf.name);
				tl.coerce(closureSig(), ret);
			case FStatic(c, cf) if (!isExtern(c)):
				var f = tl.staticField(c, cf);
				if (!needVal(ret)) return;
				tl.volatilePrefix(cf);
				code.opToken(IlOps.LDSFLD, f.token, 0, 1);
				tl.coerce(f.sig, ret);
			case FInstance(c, _, cf) | FClosure({c: c}, cf) if (isStringClass(c) && cf.kind.match(Method(_))):
				// hxcs's Runtime calls a String's methods by their Haxe names.
				pushClosure(obj, LString, cf.name);
				tl.coerce(closureSig(), ret);
			case FInstance(c, _, cf) if (isStringClass(c)):
				if (cf.name != "length") throw new Unsupported("the String field " + cf.name, false);
				tl.texpr(RValue(LString), obj);
				callString("get_Length", LInt32, []);
				tl.coerce(LInt32, ret);
			case FInstance(_, _, cf) if (cf.name == "Length" && isNativeArray(obj.type)):
				nativeLength(ret, obj);
			case FStatic(c, cf) | FInstance(c, _, cf) | FClosure({c: c}, cf) if (isExtern(c) && cf.kind.match(Method(_))):
				// A .NET method as a value, which Runtime.callField reaches by reflection.
				var isStatic = fa.match(FStatic(_, _));
				pushClosure(isStatic ? null : obj, parentOf(c, instantiation(c, fa)), ExternMembers.memberName(cf));
				tl.coerce(closureSig(), ret);
			case FStatic(c, cf) | FInstance(c, _, cf) if (isExtern(c)):
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
			case FInstance(_, _, cf) | FClosure(_, cf) if (cf.kind.match(Method(_)) && isDynamicArray(obj.type)):
				// gencs reads a method of an Array<Dynamic>, the non-generic Array, through Runtime.getField.
				tl.dyn.fieldGet(ret, e, obj, cf.name, e.type, true);
			case FInstance(c, _, cf) | FClosure({c: c}, cf) if (isMethod(cf)):
				// An instance method as a value: `new Closure(obj, "name", hash)`, the receiver evaluated now,
				// the method found by name when the closure is called.
				g.types.checkKept(TClassDecl(c));
				pushClosure(obj, LObject, cf.name);
				tl.coerce(closureSig(), ret);
			case FInstance(c, cparams, cf) | FClosure({c: c, params: cparams}, cf):
				// A variable, or a dynamic method (read as a value, the typer's FClosure), its field.
				var f = instanceField(c, cparams, cf);
				receiver(obj, f.owner);
				tl.volatilePrefix(cf);
				code.opToken(IlOps.LDFLD, f.token, 1, 1);
				tl.coerce(f.sig, ret);
			case FStatic(_, _):
				throw new Unsupported("this kind of field access", false);
			case FAnon(_) | FDynamic(_) if (tl.dyn.isDynamicReceiver(fa, obj)):
				// Runtime.getField, as gencs reads a field of a Dynamic or an anonymous structure.
				tl.dyn.fieldGet(ret, e, obj, TexprDynamic.fieldName(fa), e.type, true);
			case FAnon(_):
				throw new Unsupported("anonymous structure fields", true);
			case FDynamic(_):
				throw new Unsupported("dynamic field access", false);
			case FClosure(_, _):
				throw new Unsupported("method closures", true);
			case FEnum(en, ef) if (HxGen.isClrEnum(en)):
				// A CLR enum's literal, its index.
				if (!needVal(ret)) return;
				g.types.checkKept(TEnumDecl(en));
				code.ldcI4(ef.index);
				tl.coerce(tl.sig(e.type), ret);
			case FEnum(en, ef) if (en.isExtern):
				// A .NET enum's literal, its value in the referenced assembly.
				if (!needVal(ret)) return;
				externEnumLiteral(en, ef);
				tl.coerce(tl.sig(e.type), ret);
			case FEnum(en, ef) if (EnumToIl.isHxGenEnum(en)):
				// A constructor without arguments is the base class's static field holding its one value.
				g.types.checkKept(TEnumDecl(en));
				var plan = g.enumPlans.get(en);
				if (!plan.isSingleton(ef)) {
					// One with arguments, as a value: a closure of the base class's factory.
					pushClosure(null, plan.base.thisSig, ef.name);
					tl.coerce(closureSig(), ret);
					return;
				}
				if (!needVal(ret)) return;
				code.opToken(IlOps.LDSFLD, plan.singleton(ef), 0, 1);
				tl.coerce(plan.base.thisSig, ret);
			case FEnum(_, _):
				throw new Unsupported("enum constructors", true);
		}
	}

	// Pushes the value of a constructor of an extern .NET enum.
	function externEnumLiteral(en:TEnum, ef:TEnumField):Void {
		var lit = g.externs.enumLiteral(en, ef);
		constant(lit.c, lit.underlying);
	}

	// A native array's Length: ldlen, then the native int as an Int.
	function nativeLength(ret:Ret, obj:TExpr):Void {
		tl.texpr(RValue(vectorSig(obj)), obj);
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
			var s = tl.sig(inner.type);
			// A Null<T> goes to Std.string as an object, as its Dynamic argument takes it.
			if (tl.isHaxeNull(s)) return null;
			stringKind(s);
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

	// Pushes the arguments as the parameters' types `slots`. `targets`, the parameters' Haxe types where the
	// call knows them, decides a cast between instantiations of a generic Haxe class (TexprToIl.texprTo).
	function pushArgs(args:Array<TExpr>, slots:Array<IlSigNorm>, ?targets:Array<T>):Void {
		if (args.length != slots.length) throw new Unsupported("calls that leave out arguments", true);
		if (targets != null && targets.length != args.length) targets = null;
		for (i in 0...args.length) switch (slots[i]) {
			case LManagedPointer(t):
				// cs.Ref and cs.Out: the address of a variable of exactly that type, as C#'s ref and out.
				var s = try tl.sig(args[i].type) catch (_:Unsupported) null;
				if (s == null || !IlPaths.sigEq(s, t) || !pushAddress(args[i], true))
					throw new Unsupported("by-reference arguments that are not variables of the parameter's type", true);
			case s:
				tl.texprTo(s, targets == null ? null : targets[i], args[i]);
		}
	}

	// The argument types of the constructor of `c` (its own or an ancestor's) that `args` reach, with `params`
	// applied, as pushArgs takes them; null when there is none.
	static function ctorTargets(c:TClass, params:TParams, args:Array<TExpr>):Null<Array<T>> {
		var owner = try TypeFunctions.getConstructorClass(c, params) catch (_:Dynamic) null;
		var r = owner == null ? null : OverloadResolution.maybeResolveConstructorOverload(c, params, args);
		return r == null ? null : argTypes(TypeFunctions.applyParams(owner.c.params, owner.tl, r.cf.type));
	}

	// The argument types of the function type `t`, as a call applies them; null when it is no function.
	static function argTypes(t:T):Null<Array<T>> {
		return switch (TypeFunctions.follow(t)) {
			case TFun(fsig): [for (a in fsig.args) a.t];
			case _: null;
		}
	}

	function call(ret:Ret, e:TExpr, callee:TExpr, args:Array<TExpr>):Void {
		switch (callee.expr) {
			case TField(_, FStatic(c, cf)) if (isStd(c) && cf.name == "int" && args.length == 1):
				// As gencs writes Std.int: a C# cast (of a Dynamic converted by Runtime.toDouble).
				tl.texpr(RValue(LFloat64), args[0]);
				code.op(IlOps.CONV_I4, 1, 1);
				tl.coerce(LInt32, ret);
			case TField(_, FStatic(c, cf)) if (isStd(c) && (cf.name == "isOfType" || cf.name == "is") && args.length == 2
				&& strip(args[1]).expr.match(TTypeExpr(_))):
				tl.dyn.isOfType(ret, args[0], strip(args[1]));
			case TField(obj, FDynamic(name)) if (objectMember(name, args.length) != null):
				// Object's own members, which gencs calls directly on a Dynamic.
				var m = objectMember(name, args.length);
				tl.texpr(RValue(LObject), obj);
				for (a in args) tl.texpr(RValue(LObject), a);
				code.opToken(IlOps.CALLVIRT, g.mb.memberRef(g.typeTokenOf(LObject), name, g.sigs.method(true, m, [for (_ in args) LObject], 0)),
					args.length + 1, 1);
				tl.coerce(m, ret);
			case TField(obj, fa = FDynamic(_) | FAnon(_) | FInstance(_, _, _)) if (tl.dyn.isDynamicReceiver(fa, obj)):
				// Runtime.callField, as gencs calls a method of a Dynamic, a variable of a function type or a
				// dynamic method of a Haxe interface, or a method of a value typed as a companion interface that
				// the companion lacks.
				tl.dyn.fieldCall(ret, e, obj, TexprDynamic.fieldName(fa), args);
			case TField(_, FStatic(c, cf)) if (isStd(c) && cf.name == "string" && args.length == 1 && stringArg(args[0]) != null):
				// A value of a known type prints as in a concatenation, Bool as true or false.
				tl.ops.pushString(stringArg(args[0]));
				tl.coerce(LString, ret);
			case TField(obj, FInstance(c, _, cf)) if (isStringClass(c)):
				stringCall(ret, obj, cf, args);
			case TField(obj, FInstance(_, _, cf)) if (cf.name == "get_Length" && args.length == 0 && isNativeArray(obj.type)):
				nativeLength(ret, obj);
			case TField(_, FStatic(c, cf)) if (emptyInstanceOf(e, c, cf, args) != null):
				// overloadingConstructor's init_expr_filter: Type.createEmptyInstance of a constant hxgen class
				// is `new C(EmptyObject.EMPTY)`, which runs no constructor body.
				var target = emptyInstanceOf(e, c, cf, args);
				// newobj cannot create an abstract class (gencs's C# does not compile either).
				if (TypeFunctions.hasClassFlag(target.c, CAbstract)) throw new Unsupported("Type.createEmptyInstance of an abstract class", false);
				g.types.checkKept(TClassDecl(target.c));
				var plan = g.planOf.get(target.c);
				var owner = DotnetCtx.instanceOf(plan, g.types.classArgs(target.c, target.params));
				var token = plan.classParams.length == 0 ? plan.emptyCtor.token : g.mb.memberRef(g.typeTokenOf(owner), ".ctor",
					g.sigs.method(true, LVoid, plan.emptyCtor.args, 0));
				code.ldcI4(0);
				code.opToken(IlOps.NEWOBJ, token, 1, 1);
				tl.coerce(owner, ret);
			case TField(_, FStatic(c, cf)) if (isNativeArrayClass(c) && cf.name == "make"):
				// cs.NativeArray.make(a, b): C#'s `new T[]{a, b}`, as gencs writes it.
				newVector(ret, e, args);
			case TField(_, FStatic(c, cf)) if (tl.dyn.reflectCall(ret, e, c, cf, args)):
				// Reflect.field and setField with a constant name, lowered as field access.
			case TField(_, FStatic(c, cf)) if (isStringClass(c) && cf.name == "fromCharCode"):
				stringExtCall(ret, cf.name, null, args);
			case TField(_, FStatic(c, cf)) if (isStringClass(c)):
				// The private externs name System.String's static methods, such as Compare.
				var fsig = switch (TypeFunctions.follow(cf.type)) {
					case TFun(fsig): fsig;
					case _: throw "internal error: String." + cf.name + " is not a function";
				}
				var argSigs = [for (a in fsig.args) tl.sig(a.t)], retSig = tl.sig(fsig.ret);
				pushArgs(args, argSigs);
				var token = g.mb.memberRef(g.typeTokenOf(LString), ExternMembers.memberName(cf), g.sigs.method(false, retSig, argSigs, 0));
				code.opToken(IlOps.CALL, token, argSigs.length, retSig.match(LVoid) ? 0 : 1);
				tl.coerce(retSig, ret);
			case TField(_, FStatic(_, cf) | FInstance(_, _, cf)) if (!isMethod(cf)):
				// A variable of a function type, or a dynamic method.
				invokeFunction(ret, e, callee, args);
			case TField(_, FStatic(c, cf)) if (!isExtern(c)):
				g.types.checkKept(TClassDecl(c));
				var target = pickOverload(c, [], cf, args, true);
				var plan = g.ownerOf.get(target);
				if (plan == null || !g.methodTokens.exists(target)) throw "internal error: no method " + Globals.sTypePath(c.path) + "." + cf.name;
				var m = methodRef(plan, staticOwner(plan), [], target, target.type, callee.type, receiverArgs(c, target, args));
				pushArgs(args, m.args, argTypes(callee.type));
				code.opToken(IlOps.CALL, m.token, args.length, m.ret.match(LVoid) ? 0 : 1);
				tl.coerce(m.ret, ret);
			case TField(obj, fa = FStatic(c, cf) | FInstance(c, _, cf)) if (isExtern(c)):
				externCall(ret, obj, fa, c, cf, args, callee.type);
			case TConst(TSuper):
				superCtorCall(args);
				tl.coerce(LVoid, ret);
			case TField(obj, FInstance(c, _, cf)) if (!TypeFunctions.hasClassFlag(c, CInterface) && tl.dyn.companionReceiver(obj)):
				// A method a class's companion interface declares (TexprDynamic.companionMember): the interface's.
				companionCall(ret, obj, tl.dyn.companionMember(c, cf), args, callee.type);
			case TField(obj, FInstance(c, params, cf)):
				// super.m() calls the base class's method itself.
				var isSuper = strip(obj).expr.match(TConst(TSuper));
				var m = haxeMethod(c, params, cf, args, callee.type, !isSuper);
				// A static constructor has no `this` to call the base method on non-virtually (gencs's C#,
				// `base.m()` in a static method, does not compile either).
				if (isSuper && tl.splitCtor) throw new Unsupported("super.method() calls in constructors", true);
				if (isSuper) code.ldarg(0) else receiver(obj, m.owner);
				pushArgs(args, m.args, argTypes(callee.type));
				var op = isSuper || DotnetTypes.isValueType(m.owner) ? IlOps.CALL : IlOps.CALLVIRT;
				code.opToken(op, m.token, args.length + 1, m.ret.match(LVoid) ? 0 : 1);
				tl.coerce(m.ret, ret);
			case TField(_, FEnum(en, ef)) if (EnumToIl.isHxGenEnum(en)):
				enumFactoryCall(ret, en, ef, args, callee.type);
			case TIdent(name):
				magicCall(ret, e, name, args);
			case _:
				invokeFunction(ret, e, callee, args);
		}
	}

	// `obj.name(args)` on a value typed as a companion interface, for the method `member` of a class that
	// the companion declares: callvirt on the companion's own declaration, as gencs's C# calls it (types notes
	// §5). An interface's methods that mention no type parameter are its companion's already (CompanionToIl).
	function companionCall(ret:Ret, obj:TExpr, member:{c:TClass, cf:TClassField}, args:Array<TExpr>, calleeType:T):Void {
		var m = g.methodPlans.get(member.cf), companion = g.companionPlans.get(member.c);
		var decl = null;
		if (m != null && companion != null) for (x in companion.methods) {
			if (x.kind.match(MCompanionMember) && x.name == m.name && IlPaths.sigEq(LMethod([], x.ret, x.args), LMethod([], m.ret, m.args))
				&& x.generics.length == m.generics.length)
				decl = x;
		}
		if (decl == null) throw "internal error: the companion of " + Globals.sTypePath(member.c.path) + " has no method " + member.cf.name;
		var margs = [for (t in DotnetTypes.inferParams(member.cf.params, member.cf.type, calleeType, false)) g.types.typeArg(t)];
		var token = margs.length > 0 ? g.mb.methodSpec(decl.token, g.sigs.methodSpec(margs)) : decl.token;
		var retSig = DotnetTypes.substitute(decl.ret, [], margs);
		tl.texpr(RValue(CompanionToIl.companionSig(member.c)), obj);
		pushArgs(args, [for (a in decl.args) DotnetTypes.substitute(a, [], margs)], argTypes(calleeType));
		code.opToken(IlOps.CALLVIRT, token, args.length + 1, retSig.match(LVoid) ? 0 : 1);
		tl.coerce(retSig, ret);
	}

	// A call of a function value, a haxe.lang.Function, as gencs's closuresToClass writes it. Each
	// argument is a pair: the value as a double and Runtime.undefined when its type is like a Float (not
	// an Int64), else 0.0 and the value boxed. `__hx_invoke<N>_f` when the call's type is like a Float,
	// else `_o`, the result then converted to the call's type; six arguments or more go boxed to
	// `__hx_invokeDynamic(object[])`. A callee that is not typed as a function is cast to one and always
	// gets `_o`. As NOTES §3.6 found, an Int result reaching Dynamic through an unsafe cast (an explicit
	// `cast`, or the inliner's for an argument of a Dynamic parameter, as in Sys.println) stays a Double.
	public function invokeFunction(ret:Ret, e:TExpr, callee:TExpr, args:Array<TExpr>):Void {
		var raw = rawCall == e;
		rawCall = null;
		var fc = runtimeClass("cs.internal.Function");
		var fnSig = tl.sig(TInst(fc, []));
		var typed = IlPaths.sigEq(tl.sig(callee.type), fnSig);
		if (typed) {
			tl.texpr(RValue(fnSig), callee);
		} else {
			tl.texpr(RValue(LObject), callee);
			tl.castTo(fnSig);
		}
		var own = tl.sig(e.type);
		if (args.length >= 6) {
			tl.dyn.pushObjects(args);
			code.opToken(IlOps.CALLVIRT, functionMethod(fc, "__hx_invokeDynamic"), 2, 1);
			tl.dyn.finish(LObject, own, ret);
			return;
		}
		for (a in args) {
			if (strip(a).expr.match(TUnop(Spread, _, _))) throw new Unsupported("the spread operator", false);
			if (TexprDynamic.likeFloatReal(a.type) && !TexprDynamic.likeI64Real(a.type)) {
				tl.texpr(RValue(LFloat64), a);
				pushUndefined();
			} else {
				code.opR8(IlOps.LDC_R8, 0.0, 0, 1);
				tl.texpr(RValue(LObject), a);
			}
		}
		var isFloat = typed && TexprDynamic.likeFloatReal(e.type) && !TexprDynamic.likeI64Real(e.type);
		code.opToken(IlOps.CALLVIRT, functionMethod(fc, "__hx_invoke" + args.length + (isFloat ? "_f" : "_o")), 1 + 2 * args.length, 1);
		// gencs's cast of the result to the call's type disappears under an unsafe cast, which then boxes
		// the double: `(object)f.__hx_invoke0_f()`.
		if (raw && isFloat) tl.coerce(LFloat64, ret) else tl.dyn.finish(isFloat ? LFloat64 : LObject, own, ret);
	}

	// Pushes a haxe.lang.Closure of the method `name` of `receiver`, evaluated now; of the type `owner`'s
	// static method, `typeof(owner)`, without one. Calling it calls the method by name through
	// Runtime.callField.
	public function pushClosure(receiver:Null<TExpr>, owner:IlSigNorm, name:String):Void {
		var c = runtimeClass("cs.internal.Closure");
		var plan = g.planOf.get(c);
		var ctor = null;
		if (plan != null) for (m in plan.methods) if (m.name == ".ctor" && m.args.length == 3) ctor = m;
		if (ctor == null) throw "internal error: haxe.lang.Closure has no constructor";
		if (receiver != null) tl.texpr(RValue(LObject), receiver) else pushTypeOf(owner);
		code.opToken(IlOps.LDSTR, g.mb.userString(name), 0, 1);
		code.ldcI4(FieldHashes.use(name));
		code.opToken(IlOps.NEWOBJ, ctor.token, 3, 1);
	}

	function closureSig():IlSigNorm return tl.sig(TInst(runtimeClass("cs.internal.Closure"), []));

	// A class of hxc's copy of hxcs's runtime that the code needs.
	function runtimeClass(hxPath:String):TClass {
		var c = g.runtimeClass(hxPath);
		if (c == null) throw new Unsupported("function values without " + hxPath, false);
		g.types.checkKept(TClassDecl(c));
		return c;
	}

	// The token of haxe.lang.Function's virtual method `name`.
	function functionMethod(fc:TClass, name:String):Int {
		var cf = fc.fields.get(name);
		if (cf == null) throw "internal error: haxe.lang.Function has no " + name;
		return haxeMethod(fc, [], cf, [], cf.type).token;
	}

	// Runtime.undefined, the Dynamic half of an argument passed as a double.
	function pushUndefined():Void {
		var rt = runtimeClass("cs.internal.Runtime");
		var cf = rt.statics.get("undefined");
		if (cf == null) throw new Unsupported("haxe.lang.Runtime.undefined", false);
		code.opToken(IlOps.LDSFLD, tl.staticField(rt, cf).token, 0, 1);
	}

	// A method, not a variable or a dynamic method, which is a field holding a haxe.lang.Function.
	static function isMethod(cf:TClassField):Bool {
		return cf.kind.match(Method(_)) && !cf.kind.match(Method(MethDynamic));
	}

	// An Array<Dynamic>, which hxcs declares as the non-generic Array.
	static function isDynamicArray(t:T):Bool {
		var a = arrayOf(t);
		return a != null && TexprDynamic.isTDynamic(a.params[0]);
	}

	// A constructor with arguments: its factory, each argument converted to its type in the call's
	// instantiation (`calleeType`) first, then to the factory's erased one, as Some(2) of an Opt<Float>
	// stores a boxed Float.
	function enumFactoryCall(ret:Ret, en:TEnum, ef:TEnumField, args:Array<TExpr>, calleeType:T):Void {
		g.types.checkKept(TEnumDecl(en));
		var plan = g.enumPlans.get(en);
		var erased = plan.argSigs[ef.index];
		var own = switch (TypeFunctions.follow(calleeType)) {
			case TFun(sig): [for (a in sig.args) g.types.argSig(a.t, a.opt)];
			case _: throw "internal error: the constructor " + ef.name + " is called without a function type";
		}
		if (args.length != erased.length || own.length != erased.length) throw new Unsupported("calls that leave out arguments", true);
		for (i in 0...args.length) {
			tl.texpr(RValue(own[i]), args[i]);
			tl.convert(own[i], erased[i]);
		}
		code.opToken(IlOps.CALL, plan.factory(ef), args.length, 1);
		tl.coerce(plan.base.thisSig, ret);
	}

	// The return type of System.Object's member `name` taking `argc` arguments, or null for another name.
	function objectMember(name:String, argc:Int):Null<IlSigNorm> {
		return switch [name, argc] {
			case ["ToString", 0]: LString;
			case ["GetHashCode", 0]: LInt32;
			case ["GetType", 0]: systemType;
			case ["Equals", 1]: LBool;
			case _: null;
		}
	}

	// The class a call of Type.createEmptyInstance with a constant class in gencs's model creates, with
	// its type arguments, or null.
	function emptyInstanceOf(e:TExpr, c:TClass, cf:TClassField, args:Array<TExpr>):Null<{c:TClass, params:TParams}> {
		if (c.path.pack.length != 0 || c.path.name != "Type" || cf.name != "createEmptyInstance" || args.length != 1) return null;
		var cl = switch (strip(args[0]).expr) {
			case TTypeExpr(TClassDecl(cl)): cl;
			case _: return null;
		}
		return switch (TypeFunctions.follow(e.type)) {
			case TInst(c2, params) if (c2 == cl && HxGen.isHxGen(TClassDecl(cl))):
				var plan = g.planOf.get(cl);
				plan == null || plan.emptyCtor == null ? null : {c: cl, params: params};
			case _: null;
		}
	}

	static final systemType:IlSigNorm = LClass({ns: ["System"], nested: [], name: "Type"}, []);
	static final monitor:IlSigNorm = LClass({ns: ["System", "Threading"], nested: [], name: "Monitor"}, []);

	// `new T[]{a, b}` of the call's type, a cs.NativeArray<T>.
	function newVector(ret:Ret, e:TExpr, args:Array<TExpr>):Void {
		var elem = vectorElement(tl.sig(e.type));
		var elemToken = g.typeTokenOf(elem);
		for (a in args) if (strip(a).expr.match(TUnop(Spread, _, _))) throw new Unsupported("the spread operator", false);
		// When an element holds a loop or a try, which need an empty stack, the elements are evaluated
		// first, in order, into locals, as gencs's C# evaluates a block it hoists out of the initializer
		// (`__temp_stmt1`).
		var temps:Null<Array<Int>> = null;
		if (Lambda.exists(args, needsEmptyStack)) temps = [
			for (a in args) {
				tl.texpr(RValue(elem), a);
				var t = code.addLocal(elem);
				code.stloc(t);
				t;
			}
		];
		code.ldcI4(args.length);
		code.opToken(IlOps.NEWARR, elemToken, 1, 1);
		for (i in 0...args.length) {
			code.op(IlOps.DUP, 1, 2);
			code.ldcI4(i);
			if (temps != null) code.ldloc(temps[i]) else tl.texpr(RValue(elem), args[i]);
			code.stelem(elem, () -> elemToken);
		}
		tl.coerce(LVector(elem), ret);
	}

	// Whether `e` holds something that starts on an empty stack: a loop's head or a try block. A local
	// function's body is its own method.
	static function needsEmptyStack(e:TExpr):Bool {
		return switch (e.expr) {
			case TWhile(_, _, _) | TFor(_, _, _) | TTry(_, _): true;
			case TFunction(_): false;
			case _: TexprTools.checkExpr(needsEmptyStack, e);
		}
	}

	// gencs's magic identifiers in untyped code, which hxcs's std uses: `__as__(e)` is C#'s `e as T`
	// with T the call's type, `__is__(e, T)` C#'s `e is T`, `__typeof__(T)` `typeof(T)` and
	// `__lock__(obj, block)` `lock (obj) block`. `__array__(a, b)`, which the captured_vars filter
	// writes to box a captured variable that is written, is `new T[]{a, b}`. `__refused__(what)` is what
	// ClosuresToClass could not lower.
	function magicCall(ret:Ret, e:TExpr, name:String, args:Array<TExpr>):Void {
		switch [name, args.length] {
			case ["__array__", _]:
				newVector(ret, e, args);
			case ["__refused__", 1]:
				switch (strip(args[0]).expr) {
					case TConst(TString(what)): throw new Unsupported(what, true);
					case _: throw new Unsupported("untyped code", false);
				}
			case ["__as__", 1]:
				var to = tl.sig(e.type);
				tl.texpr(RValue(LObject), args[0]);
				if (DotnetTypes.isValueType(to)) {
					code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
				} else if (isTypeParam(to)) {
					code.opToken(IlOps.ISINST, g.typeTokenOf(to), 1, 1);
					code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
				} else if (!to.match(LObject)) {
					code.opToken(IlOps.ISINST, g.typeTokenOf(to), 1, 1);
				}
				tl.coerce(to, ret);
			case ["__is__", 2]:
				var t = typeArg(args[1]);
				tl.texpr(RValue(LObject), args[0]);
				code.opToken(IlOps.ISINST, g.typeTokenOf(t), 1, 1);
				code.op(IlOps.LDNULL, 0, 1);
				code.op(IlOps.CGT_UN, 2, 1);
				tl.coerce(LBool, ret);
			case ["__typeof__", 1]:
				pushTypeOf(typeArg(args[0]));
				tl.coerce(systemType, ret);
			case ["__lock__", 2]:
				lock(args[0], args[1]);
				tl.coerce(LVoid, ret);
			case ["__cs__", 1] if (csIntLiteral(args[0]) != null):
				var lit = csIntLiteral(args[0]);
				if (lit.t.match(LInt32 | LUInt32)) code.ldcI4(lit.v.low) else code.opI64(IlOps.LDC_I8, lit.v, 0, 1);
				tl.coerce(lit.t, ret);
			case _:
				throw new Unsupported("untyped code", false);
		}
	}

	// The constant of `__cs__(s)` when s is a C# integer literal, such as hxcs's `0xffffffffL` in
	// haxe.Int64.make, with the type C# gives it; null for any other C#, which milestone 4's subset of
	// C# expressions covers.
	static function csIntLiteral(e:TExpr):Null<{v:haxe.Int64, t:IlSigNorm}> {
		var body = switch (strip(e).expr) {
			case TConst(TString(s)): s;
			case _: return null;
		}
		var suffix = "";
		while (body.length > 0 && "uUlL".indexOf(body.charAt(body.length - 1)) >= 0) {
			suffix = body.charAt(body.length - 1).toLowerCase() + suffix;
			body = body.substr(0, body.length - 1);
		}
		if (suffix != "" && suffix != "u" && suffix != "l" && suffix != "ul" && suffix != "lu") return null;
		var hex = body.length > 2 && (body.substr(0, 2) == "0x" || body.substr(0, 2) == "0X");
		var digits = hex ? body.substr(2).toLowerCase() : body;
		// At most 16 hex or 19 decimal digits, which fit in a ulong.
		if (digits.length == 0 || digits.length > (hex ? 16 : 19)) return null;
		var v:haxe.Int64 = 0;
		for (i in 0...digits.length) {
			var d = (hex ? "0123456789abcdef" : "0123456789").indexOf(digits.charAt(i));
			if (d < 0) return null;
			v = hex ? (v << 4) | d : v * 10 + d;
		}
		// The first of int, uint, long, ulong that holds the value and that the suffix allows.
		var unsigned = suffix.indexOf("u") >= 0, long = suffix.indexOf("l") >= 0;
		inline function fits(high:Int, low:Int) return haxe.Int64.ucompare(v, haxe.Int64.make(high, low)) <= 0;
		var t = if (!long && !unsigned && fits(0, 0x7FFFFFFF)) LInt32
			else if (!long && fits(0, 0xFFFFFFFF)) LUInt32
			else if (!unsigned && fits(0x7FFFFFFF, 0xFFFFFFFF)) LInt64
			else LUInt64;
		return {v: v, t: t};
	}

	// The type a magic identifier's type argument names: a type expression, or in untyped code the name
	// of a type parameter in scope. A generic class is its instantiation with object for each parameter,
	// as gencs writes `typeof(G<object>)`, not its companion interface.
	function typeArg(e:TExpr):IlSigNorm {
		switch (strip(e).expr) {
			case TTypeExpr(mt):
				var params = [for (_ in TypeFunctions.tParams(mt)) TypeFunctions.tDynamic];
				return tl.sig(switch (mt) {
					// An abstract named as a value is its implementation class.
					case TClassDecl(c): switch (c.kind) {
							case KAbstractImpl(a): TAbstract(a, [for (_ in a.params) TypeFunctions.tDynamic]);
							case _: return g.types.classSig(c, params);
						}
					case TEnumDecl(en): TEnum(en, params);
					case TTypeDecl(td): TType(td, params);
					case TAbstractDecl(a): TAbstract(a, params);
				});
			case TIdent(name):
				var t = g.types.paramNamed(name);
				if (t != null) return tl.sig(t);
			case _:
		}
		throw new Unsupported("untyped code", false);
	}

	// typeof(T): its token, then System.Type.GetTypeFromHandle.
	function pushTypeOf(t:IlSigNorm):Void {
		var handle = LValueType({ns: ["System"], nested: [], name: "RuntimeTypeHandle"}, []);
		code.opToken(IlOps.LDTOKEN, g.typeTokenOf(t), 0, 1);
		code.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(systemType), "GetTypeFromHandle", g.sigs.method(false, systemType, [handle], 0)), 1, 1);
	}

	// C#'s `lock (obj) block`: Monitor.Enter on the object, then the block in a try whose finally calls
	// Monitor.Exit. A type expression locks its System.Type, as gencs writes `lock(typeof(T))`.
	function lock(obj:TExpr, block:TExpr):Void {
		if (code.depth != 0) throw new Unsupported("`lock` inside expressions", false);
		if (strip(obj).expr.match(TTypeExpr(_))) pushTypeOf(typeArg(obj)) else tl.texpr(RValue(LObject), obj);
		var held = code.addLocal(LObject);
		code.stloc(held);
		var enter = g.mb.memberRef(g.typeTokenOf(monitor), "Enter", g.sigs.method(false, LVoid, [LObject], 0));
		var exit = g.mb.memberRef(g.typeTokenOf(monitor), "Exit", g.sigs.method(false, LVoid, [LObject], 0));
		code.ldloc(held);
		code.opToken(IlOps.CALL, enter, 1, 0);
		tl.flow.tryFinally(() -> tl.texpr(RVoid, block), () -> {
			code.ldloc(held);
			code.opToken(IlOps.CALL, exit, 1, 0);
		});
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
		cf = declaredField(c, cf);
		var plan = g.ownerOf.get(cf);
		if (plan == null || !g.fieldTokens.exists(cf)) {
			if (!TypeFunctions.isPhysicalField(cf)) throw new Unsupported("this kind of field access", false);
			throw "internal error: no field " + Globals.sTypePath(c.path) + "." + cf.name;
		}
		var inst = g.types.classArgs(plan.c, tl.ownerArgs(c, params, plan));
		var owner = DotnetCtx.instanceOf(plan, inst);
		return {token: g.memberOf(plan, owner, cf), sig: DotnetTypes.substitute(g.fieldSigs.get(cf), inst, []), owner: owner};
	}

	// The field an overriding dynamic method of `c` stands for: the one its superclass declares.
	static function declaredField(c:TClass, cf:TClassField):TClassField {
		var cur = c;
		while (cf.kind.match(Method(MethDynamic)) && TypeFunctions.hasClassFieldFlag(cf, CfOverride) && cur.superClass != null) {
			cur = cur.superClass.c;
			var f = cur.fields.get(cf.name);
			if (f != null) cf = f;
		}
		return cf;
	}

	// A method's token as a call reaches it, with a MethodSpec for a generic method, and its argument
	// and return types there. `declared` is the method's type with the class's type arguments applied;
	// the call's `calleeType` gives the method's own, those `given` binds aside.
	function methodRef(plan:ClassPlan, owner:IlSigNorm, inst:Array<IlSigNorm>, target:TClassField, declared:T,
			calleeType:T, ?given:Array<Null<T>>):{token:Int, args:Array<IlSigNorm>, ret:IlSigNorm} {
		var token = g.memberOf(plan, owner, target);
		var margs = [for (t in DotnetTypes.inferParams(target.params, declared, calleeType, false, given)) g.types.typeArg(t)];
		if (margs.length > 0) token = g.mb.methodSpec(token, g.sigs.methodSpec(margs));
		var m = g.methodSigs.get(target);
		return {
			token: token,
			args: [for (a in m.args) DotnetTypes.substitute(a, inst, margs)],
			ret: DotnetTypes.substitute(m.ret, inst, margs)
		};
	}

	// What a call of an abstract's member method `cf` binds of its type parameters before the call's
	// types do: the abstract's own, which come last (GenerateDotnet.addAbstractParams), from the receiver,
	// the first argument. `listInts().then(f)` with a Pr<Int> receiver is `then<R,int>`. hxc's typer
	// types the call of an implicit member `@:to` cast without the abstract's type arguments applied, so
	// the call's type cannot give them there; Haxe's applies them, and gencs has `toArr<int>`. Null where
	// the receiver is not of the abstract's type (`this1` inside the abstract), which the call's types
	// then bind.
	static function receiverArgs(c:TClass, cf:TClassField, args:Array<TExpr>):Null<Array<Null<T>>> {
		var a = switch (c.kind) {
			case KAbstractImpl(a) if (a.params.length > 0 && args.length > 0 && GenerateDotnet.isAbstractMember(cf)): a;
			case _: return null;
		}
		var first = cf.params.length - a.params.length;
		if (first < 0 || cf.params[first] != a.params[0]) return null;
		return switch (TypeFunctions.follow(args[0].type)) {
			case TAbstract(a2, tl) if (a2 == a && tl.length == a.params.length):
				[for (i in 0...cf.params.length) i < first || TypeFunctions.follow(tl[i - first]).match(TMono(_)) ? null : tl[i - first]];
			case _: null;
		}
	}

	// A Haxe class's instance method, the overload the call reaches. A virtual call of an @:overload override
	// that erasure gave a bridge reaches, as gencs's does, the overload it overrides, whose slot the bridge takes.
	function haxeMethod(c:TClass, params:TParams, cf:TClassField, args:Array<TExpr>, calleeType:T,
			isVirtual = false):{token:Int, args:Array<IlSigNorm>, ret:IlSigNorm, owner:IlSigNorm} {
		g.types.checkKept(TClassDecl(c));
		var target = pickOverload(c, params, cf, args, false);
		var declaring = g.ownerOf.get(target);
		if (isVirtual && declaring != null && declaring.c != null) {
			var o = TclassToIl.overriddenOverload(g, declaring.c, target);
			if (o != null) target = o;
		}
		var plan = g.ownerOf.get(target);
		if (plan == null || !g.methodTokens.exists(target)) throw "internal error: no method " + Globals.sTypePath(c.path) + "." + cf.name;
		var hxArgs = tl.ownerArgs(c, params, plan);
		var inst = g.types.classArgs(plan.c, hxArgs);
		var owner = DotnetCtx.instanceOf(plan, inst);
		var declared = plan.c == null ? target.type : TypeFunctions.applyParams(plan.c.params, hxArgs, target.type);
		var m = methodRef(plan, owner, inst, target, declared, calleeType);
		return {token: m.token, args: m.args, ret: m.ret, owner: owner};
	}

	// A method of a referenced assembly; super.m() calls the base method itself.
	function externCall(ret:Ret, obj:TExpr, fa:TFieldAccess, c:TClass, cf:TClassField, args:Array<TExpr>, calleeType:T):Void {
		var isStatic = fa.match(FStatic(_, _));
		var isSuper = !isStatic && strip(obj).expr.match(TConst(TSuper));
		var inst = instantiation(c, fa);
		// The extern method's type arguments, inferred from the call as for a Haxe method.
		var own:Array<IlSigNorm> = [];
		if (cf.params.length > 0) {
			var declared = switch (fa) {
				case FInstance(_, params, _): TypeFunctions.applyParams(c.params, params, cf.type);
				case _: cf.type;
			}
			own = [for (t in DotnetTypes.inferParams(cf.params, declared, calleeType, false)) g.types.nativeArg(t)];
		}
		var site = externCallSite(args, inst, own);
		var start = isStatic ? null : receiverClass(obj, c);
		if (start != null) {
			site.receiver = start.c;
			site.receiverArgs = start.args;
		}
		var m = g.externs.method(c, cf, false, site);
		// A generic method's type arguments: those the call's argument types give when the extern method has
		// no type parameters (ExternMembers.method), else the extern method's own.
		var margs:Array<IlSigNorm> = m.typeArgs != null ? m.typeArgs : own;
		// Matching skips methods of another generic arity, so this fires only after a matching bug.
		if (m.typeArgs == null && cf.params.length != m.genericCount || m.typeArgs != null && m.typeArgs.length != m.genericCount)
			throw Unsupported.bug("a .NET method with another generic arity (internal: overload matching)");
		var parent = ExternMembers.subst(m.parent, start != null ? start.args : inst);
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
		pushExternArgs(args, [for (a in ilArgs) DotnetTypes.substitute(a, parentArgs, margs)], m.omitted);
		var token = g.mb.memberRef(g.typeTokenOf(parent), m.name, g.sigs.methodSig(m.sig, m.genericCount));
		if (margs.length > 0) token = g.mb.methodSpec(token, g.sigs.methodSpec(margs));
		var retSlot = DotnetTypes.substitute(ilRet, parentArgs, margs);
		var op = isStatic || isSuper || DotnetTypes.isValueType(parent) ? IlOps.CALL : IlOps.CALLVIRT;
		code.opToken(op, token, ilArgs.length + (isStatic ? 0 : 1), retSlot.match(LVoid) ? 0 : 1);
		if (retSlot.match(LVoid) && needVal(ret)) throw new Unsupported("the value of a .NET setter call", false);
		tl.coerce(retSlot, ret);
	}

	// Ruling M: where C# starts looking for an instance method `c` declares, when that is below `c`: the
	// extern class of the receiver's static type, or its nearest extern superclass that has a .NET type,
	// with its type arguments. Null where that is `c` itself or `c` is not among its superclasses (an
	// interface's method, or a receiver of another kind of type).
	function receiverClass(obj:TExpr, c:TClass):Null<{c:TClass, args:Array<IlSigNorm>}> {
		var rc:TClass, params:Array<T>;
		switch (TypeFunctions.follow(obj.type)) {
			case TInst(c1, p1) if (!c1.kind.match(KTypeParameter(_))):
				rc = c1;
				params = p1;
			case _:
				return null;
		}
		inline function up():Bool {
			var sup = rc.superClass;
			if (sup != null) {
				var cparams = rc.params, args = params;
				params = [for (p in sup.params) TypeFunctions.applyParams(cparams, args, p)];
				rc = sup.c;
			}
			return sup != null;
		}
		// The nearest extern class with a .NET type.
		while (rc != c && !(TypeFunctions.hasClassFlag(rc, CExtern) && hasNetType(rc))) if (!up()) return null;
		if (rc == c) return null;
		var start = rc, startParams = params;
		while (rc != c) if (!up()) return null;
		return {c: start, args: g.types.classArgs(start, startParams)};
	}

	// Whether the extern class `c` names a .NET type a referenced assembly defines.
	function hasNetType(c:TClass):Bool {
		return try NetRefs.of(g.ctx).definer(g.types.externPath(c)) != null catch (_:Unsupported) false;
	}

	// A .NET constructor: its MemberRef, with the arguments pushed (`argc` of them).
	function externCtor(c:TClass, params:TParams, args:Array<TExpr>):{token:Int, parent:IlSigNorm, argc:Int} {
		var r = OverloadResolution.maybeResolveConstructorOverload(c, params, args);
		if (r == null) throw "internal error: no constructor of " + Globals.sTypePath(c.path) + " fits";
		if (r.c != c) throw new Unsupported("inherited .NET constructors", true);
		var classArgs = g.types.classArgs(c, params);
		var m = g.externs.method(c, r.cf, false, externCallSite(args, classArgs, []));
		var parent = ExternMembers.subst(m.parent, classArgs);
		var parentArgs = switch (parent) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
		var ilArgs = switch (m.sig) {
			case LMethod(_, _, l): l;
			case _: throw "internal error: not a method signature";
		}
		pushExternArgs(args, [for (a in ilArgs) ExternMembers.subst(a, parentArgs)], m.omitted);
		return {token: g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.methodSig(m.sig, 0)), parent: parent, argc: ilArgs.length};
	}

	// A call site of an extern method with the arguments `args`, as ExternMembers.method takes it: each
	// argument's own type, as gencs's C# sees it, unless it is Dynamic, and the type arguments of the
	// extern class and method.
	function externCallSite(args:Array<TExpr>, classArgs:Array<IlSigNorm>, methodArgs:Array<IlSigNorm>):ExternCall {
		return {
			args: args,
			argTypes: [for (a in args) TexprDynamic.isDynamic(a.type) ? null : try tl.sig(a.type) catch (_:Unsupported) null],
			caller: tl.cls,
			classArgs: classArgs,
			methodArgs: methodArgs
		};
	}

	// Pushes the arguments of a call of a .NET method whose parameters are of the types `slots`: those
	// given, then a default for each one the call leaves out, `omitted`.
	function pushExternArgs(args:Array<TExpr>, slots:Array<IlSigNorm>, omitted:Array<IlMethodArg>):Void {
		if (args.length + omitted.length != slots.length) throw new Unsupported("calls that leave out arguments", true);
		pushArgs(args, slots.slice(0, args.length));
		for (i in 0...omitted.length) pushDefault(omitted[i], slots[args.length + i]);
	}

	// Pushes what C# passes for the parameter `arg`, of the type `slot`, that a call leaves out, as Roslyn
	// fills it from the metadata (values notes §2): its Constant row's value (a Nullable<A>'s wrapped, a
	// value going to a reference type boxed, null to a value type default(T)), its DecimalConstant or
	// DateTimeConstant attribute's, an empty params array, or for an [Optional] parameter without a value
	// System.Reflection.Missing.Value going to object and default(T) otherwise.
	function pushDefault(arg:IlMethodArg, slot:IlSigNorm):Void {
		var inner = switch (slot) {
			case LValueType(_, [a]) if (DotnetTypes.isSystemNullable(slot)): a;
			case _: null;
		}
		// Wraps the value on the stack when the slot is its Nullable.
		function wrap():Void {
			if (inner != null) tl.convert(inner, slot);
		}
		switch (arg.pdefault) {
			case PDecimal(scale, negative, hi, mid, lo):
				var decimal = LValueType(systemPath("Decimal"), []);
				code.ldcI4(lo);
				code.ldcI4(mid);
				code.ldcI4(hi);
				code.ldcI4(negative ? 1 : 0);
				code.ldcI4(scale);
				code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(decimal), ".ctor", g.sigs.method(true, LVoid, [LInt32, LInt32, LInt32, LBool, LUInt8], 0)), 5, 1);
				wrap();
				return;
			case PDateTime(ticks):
				var dateTime = LValueType(systemPath("DateTime"), []);
				code.opI64(IlOps.LDC_I8, ticks, 0, 1);
				code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(dateTime), ".ctor", g.sigs.method(true, LVoid, [LInt64], 0)), 1, 1);
				wrap();
				return;
			case PParamArray:
				var elem = switch (slot) {
					case LVector(t): t;
					case _: throw "internal error: a params parameter that is no array";
				}
				var empty = g.mb.memberRef(g.typeTokenOf(LClass(systemPath("Array"), [])), "Empty", g.sigs.method(false, LVector(LMethodTypeParam(0)), [], 1));
				code.opToken(IlOps.CALL, g.mb.methodSpec(empty, g.sigs.methodSpec([elem])), 0, 1);
				return;
			case null:
		}
		switch (arg.constant) {
			case null if (slot.match(LObject)):
				var missing = LClass({ns: ["System", "Reflection"], nested: [], name: "Missing"}, []);
				code.opToken(IlOps.LDSFLD, g.mb.memberRef(g.typeTokenOf(missing), "Value", g.sigs.field(missing)), 0, 1);
			case null | INull:
				tl.pushDefault(slot);
			case k:
				var t = inner != null ? inner : slot;
				var stored = switch (t) {
					case LValueType(p, []):
						var u = g.externs.enumUnderlying(p);
						u != null ? u : t;
					case _: t;
				}
				var pushed = constant(k, stored);
				if (inner != null) wrap() else if (pushed != null && DotnetTypes.isValueType(pushed) && !DotnetTypes.isValueType(slot))
					code.opToken(IlOps.BOX, g.typeTokenOf(pushed), 1, 1);
		}
	}

	static function systemPath(name:String):IlPath return {ns: ["System"], nested: [], name: name};

	// A Haxe class's constructor: the one the arguments reach, or the implicit one; 0 for a struct's
	// parameterless one, which is not declared.
	function haxeCtor(c:TClass, params:TParams, args:Array<TExpr>):{token:Int, args:Array<IlSigNorm>, owner:IlSigNorm} {
		g.types.checkKept(TClassDecl(c));
		var plan = g.planOf.get(c);
		if (plan == null) throw "internal error: no plan for " + Globals.sTypePath(c.path);
		var inst = g.types.classArgs(c, params);
		var owner = DotnetCtx.instanceOf(plan, inst);
		var m:Null<MethodPlan> = null;
		if (plan.ctors != null) {
			// gencs's model: the class's own constructor, or one cloned from an ancestor's, that the
			// arguments reach.
			var origin = null;
			if (TypeFunctions.hasConstructor(c)) {
				var r = OverloadResolution.maybeResolveConstructorOverload(c, params, args);
				if (r == null) throw "internal error: no constructor of " + Globals.sTypePath(c.path) + " fits";
				origin = r.cf;
			}
			m = TclassToIl.ctorOf(plan, origin).real;
		} else if (c.constructor == null || TypeFunctions.hasClassFieldFlag(c.constructor, CfExtern)) {
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

	// super(...): the base class's constructor on `this`; in a static constructor, the base class's
	// static constructor on `__hx_this`.
	function superCtorCall(args:Array<TExpr>):Void {
		var s = tl.cls == null ? null : tl.cls.superClass;
		if (s == null || tl.thisSig == null) throw new Unsupported("`super` calls", true);
		if (tl.splitCtor) {
			g.types.checkKept(TClassDecl(s.c));
			var plan = g.planOf.get(s.c);
			var r = OverloadResolution.maybeResolveConstructorOverload(s.c, s.params, args);
			if (r == null) throw "internal error: no constructor of " + Globals.sTypePath(s.c.path) + " fits";
			var stat = TclassToIl.ctorOf(plan, r.cf).stat;
			var margs = g.types.classArgs(s.c, s.params);
			code.ldarg(0);
			pushArgs(args, [for (i in 1...stat.args.length) DotnetTypes.substitute(stat.args[i], [], margs)], ctorTargets(s.c, s.params, args));
			code.opToken(IlOps.CALL, TclassToIl.staticCtorRef(g, plan, stat, margs), args.length + 1, 0);
			return;
		}
		if (isExtern(s.c)) {
			code.ldarg(0);
			var ctor = externCtor(s.c, s.params, args);
			code.opToken(IlOps.CALL, ctor.token, ctor.argc + 1, 0);
			return;
		}
		var ctor = haxeCtor(s.c, s.params, args);
		if (ctor.token == 0) throw "internal error: no constructor of " + Globals.sTypePath(s.c.path);
		code.ldarg(0);
		pushArgs(args, ctor.args, ctorTargets(s.c, s.params, args));
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
			// Where the array becomes an erased instantiation's storage, as hxcs's inlined Array.alloc makes
			// it for map (`new Array<object>((object[]) new object[n])` in gencs's C#), it is an object[]:
			// gencs erases the inlined method's type parameter there. A NativeArray<C> made for itself stays
			// a C[].
			switch (ret) {
				case RValue(LVector(LObject)) if (!elem.match(LObject)): elem = LObject;
				case _:
			}
			tl.texpr(RValue(LInt32), args[0]);
			code.opToken(IlOps.NEWARR, g.typeTokenOf(elem), 1, 1);
			tl.coerce(LVector(elem), ret);
			return;
		}
		if (isExtern(c)) {
			var ctor = externCtor(c, params, args);
			code.opToken(IlOps.NEWOBJ, ctor.token, ctor.argc, 1);
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
			pushArgs(args, ctor.args, ctorTargets(c, params, args));
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

	// The type of the native array `e` as it is read. A variable of a generic Haxe class holds the array
	// of its erased instantiation, whatever the access's Haxe type says: Array<C>'s __a, inlined from
	// hxcs's Array, is an object[], whose elements convert as they are read, as in gencs's C#.
	function vectorSig(e:TExpr):IlSigNorm {
		switch (strip(e).expr) {
			case TField(_, FInstance(c, params, cf)) if (!isExtern(c) && cf.kind.match(Var(_))):
				var s = try instanceField(c, params, cf).sig catch (_:Unsupported) null;
				if (s != null && s.match(LVector(_))) return s;
			case _:
		}
		return tl.sig(e.type);
	}

	// Whether `e1[i]` is reached through Runtime.callField's "__get" and "__set", as gencs reaches an element
	// of a Dynamic, and of an Array<Dynamic>, whose type is Array's companion interface, which has no indexer
	// before hxcs's @:classCode is (plan 3c's ruling).
	function isDynamicArrayAccess(e1:TExpr):Bool {
		if (isNativeArray(e1.type)) return false;
		return arrayOf(e1.type) == null ? TexprDynamic.isDynamic(e1.type) : g.types.isCompanionTyped(e1.type);
	}

	// Whether `e` is a native array field read through Runtime from a value typed as a companion interface,
	// such as hxcs's Array `__a` in the inlined map and filter on an Array<Dynamic>: its CLR type depends on
	// the object's instantiation (an int[] for an Array<Int> held as an Array<Dynamic>), so its elements are
	// reached through System.Array's GetValue and SetValue. gencs casts it to object[], which throws for an
	// int[] (types notes §5); decision 4 of plan 3c keeps hxc's working.
	function isDynamicVector(e:TExpr):Bool {
		return isNativeArray(e.type) && switch (strip(e).expr) {
			case TField(obj, fa = FInstance(_, _, _)): tl.dyn.companionReceiver(obj) && tl.dyn.isDynamicReceiver(fa, obj);
			case _: false;
		}
	}

	static final systemArray:IlSigNorm = LClass({ns: ["System"], nested: [], name: "Array"}, []);

	// Pushes the native array `e1` (isDynamicVector), read with Runtime.getField and not converted to its
	// Haxe type, as a System.Array, then the index `e2` as an Int.
	function pushDynamicVector(e1:TExpr, e2:TExpr):Void {
		switch (strip(e1).expr) {
			case TField(obj, fa):
				tl.dyn.fieldHead(obj, TexprDynamic.fieldName(fa));
				code.ldcI4(1);
				tl.dyn.runtimeCall("getField", LObject);
			case _:
				throw "internal error: not a field read";
		}
		code.opToken(IlOps.CASTCLASS, g.typeTokenOf(systemArray), 1, 1);
		tl.nullOperand(RValue(LInt32), e2, false);
	}

	// System.Array's GetValue(int) or SetValue(object, int) on what is on the stack.
	function callArrayValue(set:Bool):Void {
		var token = g.mb.memberRef(g.typeTokenOf(systemArray), set ? "SetValue" : "GetValue",
			g.sigs.method(true, set ? LVoid : LObject, set ? [LObject, LInt32] : [LInt32], 0));
		code.opToken(IlOps.CALLVIRT, token, set ? 3 : 2, set ? 0 : 1);
	}

	// Pushes a native array and an index into it; returns the element type.
	function pushArrayAndIndex(e1:TExpr, e2:TExpr):IlSigNorm {
		var vec = vectorSig(e1);
		tl.texpr(RValue(vec), e1);
		tl.nullOperand(RValue(indexSig(e2)), e2, false);
		return vectorElement(vec);
	}

	// a[i]: ldelem on a native array, Array's __get on an Array, and on a Dynamic or an Array<Dynamic>
	// gencs's Runtime.callField(a, "__get", hash, new object[]{i}).
	function arrayRead(ret:Ret, e:TExpr, e1:TExpr, e2:TExpr):Void {
		if (tl.sig(e1.type).match(LString)) {
			// s[i] on a String is C#'s indexer, a Char16.
			tl.texpr(RValue(LString), e1);
			tl.nullOperand(RValue(indexSig(e2)), e2, false);
			callString("get_Chars", LChar, [LInt32]);
			tl.coerce(LChar, ret);
			return;
		}
		if (isDynamicVector(e1)) {
			pushDynamicVector(e1, e2);
			callArrayValue(false);
			tl.coerce(LObject, ret);
			return;
		}
		if (isNativeArray(e1.type)) {
			var elem = pushArrayAndIndex(e1, e2);
			code.ldelem(elem, () -> g.typeTokenOf(elem));
			tl.coerce(elem, ret);
			return;
		}
		if (isDynamicArrayAccess(e1)) {
			tl.dyn.fieldCall(ret, e, e1, "__get", [e2]);
			return;
		}
		if (arrayOf(e1.type) == null) throw new Unsupported("array access", false);
		var m = arrayAccessor(e1.type, "__get");
		receiver(e1, m.owner);
		tl.nullOperand(RValue(m.args[0]), e2, false);
		code.opToken(IlOps.CALLVIRT, m.token, 2, 1);
		tl.coerce(m.ret, ret);
	}

	// [e1, e2]: a native array filled with stelem, then new Array<T>(native).
	function arrayLiteral(ret:Ret, e:TExpr, el:Array<TExpr>):Void {
		var a = arrayOf(e.type);
		if (a == null) throw new Unsupported("array literals", true);
		g.types.checkKept(TClassDecl(a.c));
		var plan = g.planOf.get(a.c);
		var elem = g.types.classArgs(a.c, a.params)[0];
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
			tl.texprStore(elem, a.params[0], el[i]);
			code.stelem(elem, () -> elemToken);
		}
		code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(owner), ".ctor", g.sigs.method(true, LVoid, ctor.args, 0)), 1, 1);
		tl.coerce(owner, ret);
	}
}
