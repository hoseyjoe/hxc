import haxe.macro.Context;
import haxe.macro.Expr;

class M {
	#if macro
	static function names(fields:Array<haxe.macro.Type.ClassField>):String
		return "[" + [for (f in fields) f.name].join(",") + "]";
	#end

	// What the class being built and its superclass hold while the build runs.
	macro public static function show():Array<Field> {
		var c = Context.getLocalClass().get();
		var sup = c.superClass == null ? "-" : names(c.superClass.t.get().fields.get());
		Context.warning(c.name + " fields=" + names(c.fields.get()) + " statics=" + names(c.statics.get())
			+ " constructor=" + (c.constructor != null) + " super=" + sup, Context.currentPos());
		return null;
	}

	macro public static function keep():Array<Field>
		return Context.getBuildFields();

	// Drops the declared fields the superclass already has.
	macro public static function dropInherited():Array<Field> {
		var sup = Context.getLocalClass().get().superClass.t.get();
		var inherited = [for (f in sup.fields.get()) f.name];
		return [for (f in Context.getBuildFields()) if (inherited.indexOf(f.name) == -1) f];
	}
}
