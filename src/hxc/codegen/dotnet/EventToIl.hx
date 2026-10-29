package hxc.codegen.dotnet;

import haxe.ds.ObjectMap;
import haxe.ds.StringMap;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.TclassToIl;

// A C# event of a Haxe class, as gencs's gen_event writes one for an @:event var of (default, default) access
// whose class has the methods add_X and remove_X (Filters.checkCsEvents makes sure it does). The var `cf` has
// no field. The event is the Event row `name` of the delegate type `sig`, with the public accessors
// `add_X(value)` and `remove_X(value)` (SpecialName, Static for a static event, Family for a @:protected var)
// that call the private non-virtual bodies the Haxe methods become, `_add_X` and `_remove_X`
// (`addBody`, `removeBody`). Every Haxe use of add_X and remove_X calls the accessor, as gencs writes
// `s.X += h` and `s.X -= h`. Reading or assigning the var is refused: C# lets an event with accessors of its
// own appear only on the left of `+=` and `-=` (CS0079).
//
// A field-like event (`fieldLike`: C# `event T X;`, whose accessors the compiler writes over a private
// `backing` field) is not written yet, so every event is planned as a custom one.
//
// Where gencs's C# fails to compile, hxc says so instead: an instance event of an hxgeneric class (CS0686), a Haxe
// override of an event's add_ or remove_ (CS0115) and a read of the var (CS0079) are errors, and the event's
// type must be a delegate (CS0066). A DCE that keeps the var and both methods together (Dce.eventSiblings) makes
// an event whose var Haxe never reads still an event, where gencs's C# fails (CS1061).
typedef EventPlan = {
	cf:TClassField,
	name:String,
	sig:IlSigNorm,
	isStatic:Bool,
	fieldLike:Bool,
	// The Haxe methods add_X and remove_X, and the private methods they become.
	addCf:TClassField,
	removeCf:TClassField,
	addBody:Null<MethodPlan>,
	removeBody:Null<MethodPlan>,
	adder:MethodPlan,
	remover:MethodPlan,
	backing:Null<FieldPlan>,
	// The Event row's token, set when the row is written.
	token:Int
};

class EventToIl {
	// An @:event var Haxe's check_cs_events and gencs's gen_event make a C# event of. Another access (haxeui's
	// builder macro turns its @:event vars into (default, set) ones) is a plain variable.
	public static function isEventVar(cf:TClassField):Bool {
		return switch (cf.kind) {
			case Var(v): v.read == AccNormal && v.write == AccNormal && TypeFunctions.hasMeta(":event", cf.meta);
			case _: false;
		}
	}

	// The class's events (its extern ones are the .NET assembly's): the statics', then the instances', each
	// last declared first, as gencs declares them; the event of each add_X and remove_X body (`bodies`); and
	// the vars (`vars`), which have no field. `implementing` holds the class's methods that implement a method
	// of an interface it lists: an accessor of those is virtual and sealed, as C# makes it.
	public static function planEvents(g:DotnetCtx, c:TClass, implementing:ObjectMap<TClassField, Bool>):{
		list:Array<EventPlan>,
		bodies:ObjectMap<TClassField, EventPlan>,
		vars:ObjectMap<TClassField, EventPlan>
	} {
		var list:Array<EventPlan> = [];
		var bodies = new ObjectMap<TClassField, EventPlan>();
		var vars = new ObjectMap<TClassField, EventPlan>();
		function collect(fields:Array<TClassField>, isStatic:Bool) {
			var table = isStatic ? c.statics : c.fields;
			var found:Array<EventPlan> = [];
			for (cf in fields) {
				if (!isEventVar(cf) || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) continue;
				try {
					found.push(planEvent(g, c, cf, table, isStatic, implementing));
				} catch (u:Unsupported) {
					if (u.pos == null) u.pos = cf.pos;
					throw u;
				}
			}
			found.reverse();
			for (e in found) {
				list.push(e);
				vars.set(e.cf, e);
				bodies.set(e.addCf, e);
				bodies.set(e.removeCf, e);
			}
		}
		collect(c.orderedStatics, true);
		collect(c.orderedFields, false);
		return {list: list, bodies: bodies, vars: vars};
	}

	static function planEvent(g:DotnetCtx, c:TClass, cf:TClassField, table:StringMap<TClassField>, isStatic:Bool,
			implementing:ObjectMap<TClassField, Bool>):EventPlan {
		function method(prefix:String):TClassField {
			var m = table.get(prefix + cf.name);
			if (m == null || !m.kind.match(Method(_))) throw Unsupported.bug("the @:event var " + cf.name + " has no method " + prefix + cf.name);
			if (m.overloads.length > 0 || m.params.length > 0 || !m.kind.match(Method(MethNormal | MethInline)) || TypeFunctions.hasClassFieldFlag(m, CfAbstract))
				throw new Unsupported("event methods that are overloaded, generic, dynamic or abstract (" + m.name + ")", true, m.pos);
			return m;
		}
		var sig = g.types.toSig(cf.type);
		if (!g.externs.isDelegateType(sig)) throw Unsupported.error("the type of the @:event var " + cf.name + " is no .NET delegate type (C# error CS0066)");
		var name = DotnetNames.fieldName(c, cf.name);
		var e:EventPlan = {
			cf: cf,
			name: name,
			sig: sig,
			isStatic: isStatic,
			fieldLike: false,
			addCf: method("add_"),
			removeCf: method("remove_"),
			addBody: null,
			removeBody: null,
			adder: null,
			remover: null,
			backing: null,
			token: 0
		};
		// gencs's get_fun_modifiers: @:protected on the var.
		var access = TypeFunctions.hasMeta(":protected", cf.meta) ? MethodAttrs.FAMILY : MethodAttrs.PUBLIC;
		function accessor(body:TClassField, isRemove:Bool):MethodPlan {
			var flags = access | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | (isStatic ? MethodAttrs.STATIC : 0);
			// C# makes the accessor of an event that implements an interface method final virtual.
			if (!isStatic && implementing.exists(body)) flags |= MethodAttrs.VIRTUAL | MethodAttrs.FINAL | MethodAttrs.NEW_SLOT;
			return {
				kind: MEventAccessor(e, isRemove),
				name: (isRemove ? "remove_" : "add_") + name,
				flags: flags,
				hasThis: !isStatic,
				ret: LVoid,
				args: [sig],
				argNames: ["value"],
				generics: [],
				pos: body.pos,
				token: 0
			};
		}
		e.adder = accessor(e.addCf, false);
		e.remover = accessor(e.removeCf, true);
		return e;
	}

	// The private body a Haxe add_X or remove_X became.
	public static function setBody(e:EventPlan, cf:TClassField, m:MethodPlan):Void {
		if (cf == e.addCf) e.addBody = m else e.removeBody = m;
	}

	// The plan's Event rows and their accessors' MethodSemantics rows, after its methods' rows exist, and the
	// checks that need the whole class: errors where gencs's C# fails to compile.
	public static function write(g:DotnetCtx, plan:ClassPlan):Void {
		var mb = g.mb;
		for (e in plan.events) {
			e.token = mb.event(plan.token, e.name, TclassToIl.sigToken(g, e.sig));
			mb.methodSemantics(SemanticsAttrs.ADD_ON, e.adder.token, e.token);
			mb.methodSemantics(SemanticsAttrs.REMOVE_ON, e.remover.token, e.token);
			// Every Haxe use of add_X and remove_X calls the public accessor, as gencs writes `o.X += h`.
			for (pair in [{cf: e.addCf, accessor: e.adder}, {cf: e.removeCf, accessor: e.remover}]) {
				g.methodTokens.set(pair.cf, pair.accessor.token);
				g.methodPlans.set(pair.cf, pair.accessor);
				g.methodSigs.set(pair.cf, {ret: pair.accessor.ret, args: pair.accessor.args});
			}
			// The accessors of an instance event of an hxgeneric class would implement the add_ and remove_ of its
			// companion interface, which C# refuses.
			if (!plan.isStd && !e.isStatic && (CompanionToIl.isMember(g, plan.c, e.addCf) || CompanionToIl.isMember(g, plan.c, e.removeCf)))
				g.error("an @:event var of a generic class (" + plan.hxPath + "." + e.cf.name + ") is not supported (gencs: C# error CS0686)", e.cf.pos);
		}
		if (plan.c != null && !plan.isStd) for (m in plan.methods) switch (m.kind) {
			case MField(cf) if (TypeFunctions.hasClassFieldFlag(cf, CfOverride)):
				var v = eventOfAccessor(plan.c, cf);
				if (v != null)
					g.error(plan.hxPath + "." + cf.name + " overrides the " + v.prefix + " method of the event " + DotnetTypes.haxePath(TClassDecl(v.owner)) + "."
						+ v.cf.name + ", which is no virtual method (gencs: C# error CS0115)", cf.pos);
			case _:
		}
	}

	// The @:event var a superclass of `c` declares that the add_ or remove_ method `cf` is a body of, the class
	// declaring it and the method's prefix.
	static function eventOfAccessor(c:TClass, cf:TClassField):Null<{cf:TClassField, owner:TClass, prefix:String}> {
		var prefix = StringTools.startsWith(cf.name, "add_") ? "add_" : StringTools.startsWith(cf.name, "remove_") ? "remove_" : null;
		if (prefix == null) return null;
		var name = cf.name.substr(prefix.length);
		var cur = c.superClass;
		while (cur != null) {
			var v = cur.c.fields.get(name);
			if (v != null) return isEventVar(v) && !TypeFunctions.hasClassFlag(cur.c, CExtern) ? {cf: v, owner: cur.c, prefix: prefix} : null;
			cur = cur.c.superClass;
		}
		return null;
	}

	// An accessor's body, as C# compiles gencs's `add { _add_X(value); }`: `ldarg.0; ldarg.1; call _add_X; ret`,
	// and for a static event `ldarg.0; call _add_X; ret`; a generic class's body is reached through its own
	// instantiation.
	public static function accessorBody(g:DotnetCtx, plan:ClassPlan, e:EventPlan, isRemove:Bool, code:IlCode):Void {
		var body = isRemove ? e.removeBody : e.addBody;
		if (body == null) throw "internal error: the event " + e.name + " has an accessor without a body";
		if (!e.isStatic) code.ldarg(0);
		code.ldarg(e.isStatic ? 0 : 1);
		code.opToken(IlOps.CALL, g.methodOf(plan, plan.thisSig, body), e.isStatic ? 1 : 2, 0);
		code.op(IlOps.RET, 0, 0);
	}

	// The error for a read or an assignment of the var `cf` of an event, reached through the class `c`: C# lets an
	// event with accessors of its own appear only on the left of `+=` and `-=` (CS0079).
	public static function noValue(c:TClass, cf:TClassField):Unsupported {
		var owner = c;
		while (owner.fields.get(cf.name) != cf && owner.statics.get(cf.name) != cf && owner.superClass != null) owner = owner.superClass.c;
		return Unsupported.error("the event " + DotnetTypes.haxePath(TClassDecl(owner)) + "." + cf.name
			+ " has add_/remove_ bodies, so it has no value to read or assign (C# error CS0079)");
	}
}
