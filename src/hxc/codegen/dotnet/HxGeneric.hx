package hxc.codegen.dotnet;

import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.core.Type;
import hxc.core.TypeFunctions;

// What a class's or enum's generic analysis found: hxgeneric, not, or not known yet because it reached a
// type whose own analysis is still running.
private enum Found {
	Yes;
	No;
	Unresolved;
}

// Which generic types gencs treats as "hxgeneric" (realTypeParams.ml's set_hxgeneric): it erases their
// type arguments and gives them a companion interface and casts. An hxgen generic class or interface
// is hxgeneric unless its superclass is not, or one of its instance variables has, after typedefs,
// Null and abstracts, the type of a generic class or enum that is not hxgeneric applied to something
// with a type parameter in it (`var l:List_1<T>`). cs.NativeArray<T> does not count, as gencs casts its
// type parameter itself. A class that is not hxgen, and a @:nativeGen one, is not hxgeneric; its type
// arguments stay as they are ("native generic").
//
// gencs runs the analysis in passes. A type it reaches while that type's own analysis is still running
// is unresolved, which is no evidence against either, and a type with no evidence against it is
// hxgeneric in the end. Evidence against is final, so a No is kept at once; a Yes that leaned on an
// unresolved type is kept only for the type whose analysis started the walk, the one every unresolved
// reference leads back to.
class HxGeneric {
	// Whether the class `c` is hxgeneric; false for a class without type parameters.
	public static function isHxGeneric(g:DotnetCtx, c:TClass):Bool {
		if (c.params.length == 0 || c.kind.match(KTypeParameter(_))) return false;
		var known = g.hxGenericClasses.get(c);
		if (known != null) return known;
		var r = new HxGeneric(g).ofClass(c) != No;
		g.hxGenericClasses.set(c, r);
		return r;
	}

	final g:DotnetCtx;
	// The classes and enums whose analysis is running, outermost first.
	final running:Array<ModuleType> = [];

	function new(g:DotnetCtx) {
		this.g = g;
	}

	function isRunning(mt:ModuleType):Bool {
		for (r in running) switch [r, mt] {
			case [TClassDecl(a), TClassDecl(b)] if (a == b): return true;
			case [TEnumDecl(a), TEnumDecl(b)] if (a == b): return true;
			case _:
		}
		return false;
	}

	function ofClass(c:TClass):Found {
		// A class without type parameters is no evidence against a subclass or a variable, hxgen or not:
		// a closure class extending haxe.lang.Function is hxgeneric.
		if (c.params.length == 0) return Yes;
		var known = g.hxGenericClasses.get(c);
		if (known != null) return known ? Yes : No;
		if (isRunning(TClassDecl(c))) return Unresolved;
		// A local generic function's class (ClosuresToClass) is instantiated with the function's type
		// arguments as gencs binds them for the call, erased as a generic method's are.
		if (g.closureOwners.exists(c)) return keepClass(c, Yes);
		if (!HxGen.isHxGen(TClassDecl(c)) || TypeFunctions.hasMeta(":nativeGen", c.meta)) return keepClass(c, No);
		running.push(TClassDecl(c));
		var r = try {
			var sup = c.superClass == null ? Yes : ofClass(c.superClass.c);
			if (sup == No) No else {
				var found = sup;
				for (cf in c.orderedFields) {
					var f = ofVariable(cf.type);
					if (f == No) {
						found = No;
						break;
					}
					if (f == Unresolved) found = Unresolved;
				}
				found;
			}
		} catch (e:Dynamic) {
			running.pop();
			throw e;
		}
		running.pop();
		// Every unresolved reference leads back to a type on the walk; with none left but this one, the
		// evidence is complete.
		if (r == Unresolved && running.length == 0) r = Yes;
		return r == Unresolved ? r : keepClass(c, r);
	}

	function keepClass(c:TClass, r:Found):Found {
		g.hxGenericClasses.set(c, r == Yes);
		return r;
	}

	function ofEnum(e:TEnum):Found {
		if (e.params.length == 0) return Yes;
		var known = g.hxGenericEnums.get(e);
		if (known != null) return known ? Yes : No;
		if (isRunning(TEnumDecl(e))) return Unresolved;
		if (!HxGen.isHxGen(TEnumDecl(e))) return keepEnum(e, No);
		running.push(TEnumDecl(e));
		var r = try {
			var found = Yes;
			for (name in e.names) {
				switch (TypeFunctions.follow(e.constrs.get(name).type)) {
					case TFun(sig):
						for (a in sig.args) {
							var f = ofVariable(a.t);
							if (f == No) found = No else if (f == Unresolved && found == Yes) found = Unresolved;
						}
					case _:
				}
				if (found == No) break;
			}
			found;
		} catch (x:Dynamic) {
			running.pop();
			throw x;
		}
		running.pop();
		if (r == Unresolved && running.length == 0) r = Yes;
		return r == Unresolved ? r : keepEnum(e, r);
	}

	function keepEnum(e:TEnum, r:Found):Found {
		g.hxGenericEnums.set(e, r == Yes);
		return r;
	}

	// The evidence a variable of type `t` (an enum constructor's argument) gives: No when it is a generic
	// class or enum that is not hxgeneric, applied to a type parameter somewhere.
	function ofVariable(t:T):Found {
		var r = realType(t);
		return switch (r) {
			case TInst(c, _) if (c.kind.match(KTypeParameter(_))): Yes;
			case TInst(c, _) if (hasTypeParams(r)):
				if (c.path.name == "NativeArray" && c.path.pack.length == 1 && c.path.pack[0] == "cs") Yes else ofClass(c);
			case TEnum(e, _) if (hasTypeParams(r)): ofEnum(e);
			case _: Yes;
		}
	}

	// gencs's real type: typedefs, Null and abstracts that are not core types followed to what they stand
	// for.
	static function realType(t:T):T {
		var cur = TypeFunctions.follow(t);
		for (_ in 0...50) switch (cur) {
			case TAbstract(a, pl) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
				cur = TypeFunctions.follow(TypeFunctions.getUnderlyingType(a, pl));
			case _:
				return cur;
		}
		return cur;
	}

	// has_type_params: whether a type parameter occurs in `t`, through type arguments and function types.
	static function hasTypeParams(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, _) if (c.kind.match(KTypeParameter(_))): true;
			case TInst(_, l) | TEnum(_, l) | TAbstract(_, l):
				for (p in l) if (hasTypeParams(p)) return true;
				false;
			case TFun(sig):
				for (a in sig.args) if (hasTypeParams(a.t)) return true;
				hasTypeParams(sig.ret);
			case _: false;
		}
	}
}
