package hxc.codegen.dotnet;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.codegen.dotnet.CsSyntax;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.TexprToIl.Ret;
import hxc.codegen.dotnet.TexprToIl.isTypeParam;
import hxc.codegen.dotnet.TexprToIl.isReference;
import hxc.codegen.dotnet.TexprToIl.strip;

// What a name in inline C# is: a type (a static receiver or a cast target), a namespace, or a value it has
// already pushed.
enum CsValue {
	VType(t:IlSigNorm);
	VNamespace(path:Array<String>);
	VPushed(t:IlSigNorm);
}

// A decimal constant: `mantissa` (non-negative) / 10^scale, negated when `negative`.
private typedef DecimalConst = {mantissa:haxe.Int64, negative:Bool, scale:Int};

// Inline C# (`untyped __cs__`, `cs.Syntax.code`, `cs.Syntax.plainCode`) as IL: CsSyntax's expression, its
// names resolved over CLR types and lowered with C#'s semantics (csexpr §6). Shares its state through the
// TexprToIl that owns it.
@:allow(hxc.codegen.dotnet.TexprToIl, hxc.codegen.dotnet.TexprCalls)
class CsToIl {
	final tl:TexprToIl;
	final g:DotnetCtx;
	final il:IlCode;

	// The call being lowered: its placeholders' arguments, its position (where errors go) and the position of
	// its code string (where gencs puts a placeholder's error).
	var args:Array<TExpr> = [];
	var pos:Position = Position.nullPos;
	var textPos:Position = Position.nullPos;

	static final decimal:IlSigNorm = LValueType({ns: ["System"], nested: [], name: "Decimal"}, []);

	public function new(tl:TexprToIl) {
		this.tl = tl;
		g = tl.g;
		il = tl.code;
	}

	// The code string of an inline C# call, which must be a constant (gencs's error, at the argument).
	public static function constantText(e:TExpr):String {
		return switch (strip(e).expr) {
			case TConst(TString(s)): s;
			case _: throw Unsupported.haxeError("The `code` argument for cs.Syntax.code must be a string constant", e.pos);
		}
	}

	public static function isSyntaxClass(c:TClass):Bool return c.path.pack.length == 1 && c.path.pack[0] == "cs" && c.path.name == "Syntax";

	// The inline C# call `e`, whose code string is `text` and whose placeholders' arguments are `args`,
	// where `ret` wants it. `isUntyped`: `untyped __cs__`, whose value takes the type it is used as through
	// C#'s implicit conversions; cs.Syntax's is a Dynamic, converted as gencs converts one (plan ruling 3).
	public function code(ret:Ret, e:TExpr, text:String, args:Array<TExpr>, isUntyped:Bool, pos:Position):Void {
		// A placeholder's argument may hold inline C# of its own.
		var outer = {args: this.args, pos: this.pos, textPos: this.textPos};
		function restore() {
			this.args = outer.args;
			this.pos = outer.pos;
			this.textPos = outer.textPos;
		}
		this.args = args;
		this.pos = pos;
		try {
			lower(ret, e, text, isUntyped);
		} catch (x:Dynamic) {
			restore();
			throw x;
		}
		restore();
	}

	function lower(ret:Ret, e:TExpr, text:String, isUntyped:Bool):Void {
		var plain = false;
		textPos = pos;
		switch (strip(e).expr) {
			case TCall(callee, all):
				textPos = all[0].pos;
				plain = switch (strip(callee).expr) {
					case TField(_, FStatic(_, cf)): cf.name == "plainCode";
					case _: false;
				}
			case _:
		}
		switch (CsSyntax.parse(text, !plain)) {
			case PThrow:
				if (ret.match(RValue(_))) error("a bare `throw` in inline C# has no value");
				tl.flow.rethrow(pos);
			case PRefused("statements", replacement, _):
				error("inline C# must be one expression or a bare `throw`; " + replacement);
			case PRefused(what, replacement, _):
				var plural = StringTools.endsWith(what, "arguments") || what == "pointers";
				error(what + (plural ? " are" : " is") + " not part of the inline C# subset; " + replacement);
			case PError(reason, _):
				error("inline C# does not parse: " + reason);
			case PExpr(x):
				var t = value(x);
				switch (ret) {
					case RVoid | RReturn:
						if (t == null || !t.match(LVoid)) il.op(IlOps.POP, 1, 0);
					case RValue(want):
						if (t != null && t.match(LVoid)) error("the inline C# expression has no value (C# error CS0029)");
						var target = want != null ? want : tl.sig(e.type);
						convertResult(t, target, !isUntyped, e.type);
				}
		}
	}

	function error(what:String):Dynamic {
		var u = Unsupported.error(what);
		u.pos = pos;
		throw u;
	}

	// The value of type `cs` on the stack as the `target` of the call's Haxe type `haxeType`. `castLike`
	// (cs.Syntax): as gencs converts a Dynamic, Runtime.toInt, toDouble, toBool and toString of the boxed
	// value, ofDynamic and genericCast too, and C#'s explicit cast to any other type. Otherwise C#'s implicit
	// conversions only, as gencs writes the C# with no conversion around it.
	function convertResult(cs:Null<IlSigNorm>, target:IlSigNorm, castLike:Bool, haxeType:T):Void {
		if (castLike) {
			if (fromDynamic(target)) {
				box(cs);
				tl.convert(LObject, target);
			} else {
				explicitCast(cs, target);
			}
			return;
		}
		if (cs == null) {
			if (DotnetTypes.isValueType(target)) error("the inline C# expression is null, which does not convert to "
				+ hxc.core.TPrinting.sTypeStr(haxeType) + " (C# error CS0037)");
			return;
		}
		if (!g.externs.implicitlyConverts(cs, target)) {
			var explicit = explicitlyConverts(cs, target);
			error("the inline C# expression is " + article(csName(cs)) + ", which does not convert to " + hxc.core.TPrinting.sTypeStr(haxeType)
				+ " implicitly (C# error " + (explicit ? "CS0266); add a cast in the C# text" : "CS0029)"));
		}
		tl.convert(cs, target);
	}

	// The types gencs converts a Dynamic to through the runtime (TexprDynamic.toSig): the Haxe numbers, Bool
	// and String, a type parameter, a haxe.lang.Null<T> and Dynamic itself.
	function fromDynamic(s:IlSigNorm):Bool {
		return s.match(LInt32 | LUInt32 | LInt8 | LUInt8 | LInt16 | LUInt16 | LChar | LFloat64 | LFloat32 | LBool | LString | LObject)
			|| isTypeParam(s) || tl.isHaxeNull(s);
	}

	// Whether C# has an explicit conversion from `from` to `to` where it has no implicit one (CS0266 rather
	// than CS0029): between numbers, between references, and between object and a value type.
	function explicitlyConverts(from:IlSigNorm, to:IlSigNorm):Bool {
		if (isNumber(from) && isNumber(to)) return true;
		if (isReference(from) && isReference(to)) return true;
		return from.match(LObject) && DotnetTypes.isValueType(to) || to.match(LObject) && DotnetTypes.isValueType(from);
	}

	// ---- names

	// What a name in the C# text is. Keyword types for now; any other name is unknown.
	function resolveName(x:CsExpr):CsValue {
		return switch (x.def) {
			case CKeywordType(name):
				VType(keywordType(name));
			case CIdent(name) | CGlobal(name):
				unknownName(name, "CS0103");
			case CThis:
				unknownName("this", "CS0103");
			case CMember(e1, _) | CCall(e1, _) | CIndex(e1, _):
				resolveName(e1);
				throw new Unsupported("member access, calls and indexers in inline C#", true);
			case CNew(t, _):
				resolveType(t);
				throw new Unsupported("`new` in inline C#", false);
			case _:
				VPushed(value(x));
		}
	}

	function unknownName(name:String, csError:String):Dynamic {
		return error("the inline C# name " + name + " is no local, member or type here (C# error " + csError + ")");
	}

	// A type the C# text names, as a cast or `is` target.
	function resolveType(t:CsType):IlSigNorm {
		return switch (t) {
			case CTKeyword(name): keywordType(name);
			case CTArray(t1): LVector(resolveType(t1));
			case CTNamed(_, segments, _): unknownName(segments.join("."), "CS0246");
		}
	}

	static function keywordType(name:String):IlSigNorm {
		return switch (name) {
			case "bool": LBool;
			case "byte": LUInt8;
			case "sbyte": LInt8;
			case "short": LInt16;
			case "ushort": LUInt16;
			case "int": LInt32;
			case "uint": LUInt32;
			case "long": LInt64;
			case "ulong": LUInt64;
			case "char": LChar;
			case "float": LFloat32;
			case "double": LFloat64;
			case "decimal": decimal;
			case "string": LString;
			case "object": LObject;
			case _: throw "internal error: no keyword type " + name;
		}
	}

	// A type as C# names it, for errors.
	static function csName(s:Null<IlSigNorm>):String {
		if (s == null) return "null";
		return switch (s) {
			case LBool: "bool";
			case LUInt8: "byte";
			case LInt8: "sbyte";
			case LInt16: "short";
			case LUInt16: "ushort";
			case LInt32: "int";
			case LUInt32: "uint";
			case LInt64: "long";
			case LUInt64: "ulong";
			case LChar: "char";
			case LFloat32: "float";
			case LFloat64: "double";
			case LString: "string";
			case LObject: "object";
			case LVector(e): csName(e) + "[]";
			case _ if (isDecimal(s)): "decimal";
			case LClass(p, _) | LValueType(p, _): p.ns.concat(p.nested).concat([p.name]).join(".");
			case _: Std.string(s);
		}
	}

	static function article(name:String):String return ("aeiou".indexOf(name.charAt(0)) >= 0 ? "an " : "a ") + name;

	// ---- values

	// Pushes the value of `x` and returns its type: null for the null literal, LVoid when it has none.
	function value(x:CsExpr):Null<IlSigNorm> {
		return switch (x.def) {
			case CPlaceholder(n):
				placeholder(n, x);
			case CLiteral(l):
				literal(l);
			case CParen(e1):
				value(e1);
			case CUnop("!", e1):
				boolOperand(e1);
				not();
				LBool;
			case CUnop(_, e1):
				negate(e1);
			case CBinop(op = "&&" | "||", a, b):
				shortCircuit(op == "&&", a, b);
			case CBinop(op, a, b):
				var ta = value(a);
				binary(op, a, b, ta, value(b));
			case CCast(t, e1):
				castExpr(resolveType(t), e1);
			case CIs(e1, t):
				var to = resolveType(t);
				box(value(e1));
				il.opToken(IlOps.ISINST, g.typeTokenOf(to), 1, 1);
				il.op(IlOps.LDNULL, 0, 1);
				il.op(IlOps.CGT_UN, 2, 1);
				LBool;
			case _:
				switch (resolveName(x)) {
					case VPushed(t): t;
					case VType(t): error("the inline C# type " + csName(t) + " is no value");
					case VNamespace(path): unknownName(path.join("."), "CS0103");
				}
		}
	}

	// Argument `n`, evaluated at each use as gencs's text substitution does, in its own type; a
	// haxe.lang.Null<T> goes as gencs's `toDynamic()`, an object.
	function placeholder(n:Int, x:CsExpr):IlSigNorm {
		if (n >= args.length)
			throw Unsupported.haxeError("Out-of-bounds special parameter: " + n, new Position(textPos.file, textPos.min + x.pos, textPos.max));
		var a = args[n];
		var t = tl.sig(a.type);
		if (tl.isHaxeNull(t)) t = LObject;
		tl.texpr(RValue(t), a);
		return t;
	}

	function literal(l:CsLiteral):Null<IlSigNorm> {
		switch (l) {
			case LInt(s):
				var lit = intLiteral(s);
				if (lit == null) error("inline C# does not parse: " + s + " is no C# integer literal, or too large for one");
				pushInt(lit.v, lit.t);
				return lit.t;
			case LReal(s):
				var suffix = s.charAt(s.length - 1).toLowerCase();
				var digits = "fdm".indexOf(suffix) >= 0 ? s.substr(0, s.length - 1) : s;
				switch (suffix) {
					case "m":
						var d = decimalLiteral(digits);
						if (d == null) throw new Unsupported("decimal literals of more than 18 significant digits or 28 decimals", true);
						pushDecimal(d);
						return decimal;
					case "f":
						il.opR4(IlOps.LDC_R4, Std.parseFloat(digits), 0, 1);
						return LFloat32;
					case _:
						il.opR8(IlOps.LDC_R8, Std.parseFloat(digits), 0, 1);
						return LFloat64;
				}
			case LString(s):
				il.opToken(IlOps.LDSTR, g.mb.userString(s), 0, 1);
				return LString;
			case LChar(c):
				il.ldcI4(c);
				return LChar;
			case LBool(b):
				il.ldcI4(b ? 1 : 0);
				return LBool;
			case LNull:
				il.op(IlOps.LDNULL, 0, 1);
				return null;
		}
	}

	function pushInt(v:haxe.Int64, t:IlSigNorm):Void {
		if (t.match(LInt32 | LUInt32)) il.ldcI4(v.low) else il.opI64(IlOps.LDC_I8, v, 0, 1);
	}

	// A C# integer literal, such as hxcs's `0xffffffffL` in haxe.Int64.make: its value and the type C# gives
	// it, the first of int, uint, long and ulong that holds it and that its suffix allows; null when it is
	// none or too large.
	static function intLiteral(text:String):Null<{v:haxe.Int64, t:IlSigNorm}> {
		var body = text;
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
		var unsigned = suffix.indexOf("u") >= 0, long = suffix.indexOf("l") >= 0;
		inline function fits(high:Int, low:Int) return haxe.Int64.ucompare(v, haxe.Int64.make(high, low)) <= 0;
		var t = if (!long && !unsigned && fits(0, 0x7FFFFFFF)) LInt32
			else if (!long && fits(0, 0xFFFFFFFF)) LUInt32
			else if (!unsigned && fits(0x7FFFFFFF, 0xFFFFFFFF)) LInt64
			else LUInt64;
		return {v: v, t: t};
	}

	// ---- decimal (plan ruling 5)

	static function isDecimal(s:Null<IlSigNorm>):Bool {
		return s != null && switch (s) {
			case LValueType(p, []): p.name == "Decimal" && p.nested.length == 0 && p.ns.length == 1 && p.ns[0] == "System";
			case _: false;
		}
	}

	// The digits of a real literal or a Float constant (`2.5`, `1e3`), exact: null when the mantissa has more
	// than 18 digits or the scale more than 28.
	static function decimalLiteral(s:String):Null<DecimalConst> {
		var exp = 0;
		var e = s.toLowerCase().indexOf("e");
		if (e >= 0) {
			var n = Std.parseInt(s.substr(e + 1));
			if (n == null) return null;
			exp = n;
			s = s.substr(0, e);
		}
		var dot = s.indexOf(".");
		var scale = dot < 0 ? 0 : s.length - dot - 1;
		var digits = dot < 0 ? s : s.substr(0, dot) + s.substr(dot + 1);
		while (digits.length > 1 && digits.charAt(0) == "0") digits = digits.substr(1);
		scale -= exp;
		while (scale < 0) {
			digits += "0";
			scale++;
		}
		if (digits.length > 18 || scale > 28) return null;
		var m:haxe.Int64 = 0;
		for (i in 0...digits.length) {
			var d = "0123456789".indexOf(digits.charAt(i));
			if (d < 0) return null;
			m = m * 10 + d;
		}
		return {mantissa: m, negative: false, scale: scale};
	}

	// The decimal `(decimal)x` folds to, as Roslyn does for a constant `x`: an integer literal or Int constant
	// exactly; a decimal literal as written; a real literal or Float constant as .NET's decimal(double) gives
	// it, at most 15 significant digits without trailing zeros (null, not folded, for more). A negation
	// folds too.
	function decimalConstant(x:CsExpr):Null<DecimalConst> {
		switch (x.def) {
			case CParen(e1):
				return decimalConstant(e1);
			case CUnop("-", e1):
				var d = decimalConstant(e1);
				if (d != null) d.negative = !d.negative;
				return d;
			case CLiteral(LInt(s)):
				var lit = intLiteral(s);
				return lit == null || lit.v < 0 ? null : {mantissa: lit.v, negative: false, scale: 0};
			case CLiteral(LReal(s)) if (StringTools.endsWith(s.toLowerCase(), "m")):
				return decimalLiteral(s.substr(0, s.length - 1));
			case CLiteral(LReal(s)):
				var suffix = s.charAt(s.length - 1).toLowerCase();
				return suffix == "f" ? null : fromDouble(suffix == "d" ? s.substr(0, s.length - 1) : s);
			case CPlaceholder(n) if (n < args.length):
				return switch (strip(args[n]).expr) {
					case TConst(TInt(v)):
						var m = haxe.Int64.ofInt(v);
						{mantissa: v < 0 ? -m : m, negative: v < 0, scale: 0};
					case TConst(TFloat(f)): fromDouble(f);
					case _: null;
				}
			case _:
				return null;
		}
	}

	// decimal(double) of the real written as `s`: its digits, when it has at most 15 significant ones (which a
	// double keeps), without trailing zeros after the point.
	static function fromDouble(s:String):Null<DecimalConst> {
		var negative = StringTools.startsWith(s, "-");
		var d = decimalLiteral(negative ? s.substr(1) : s);
		if (d == null || haxe.Int64.compare(d.mantissa, haxe.Int64.make(0x38D7E, 0xA4C67FFF)) > 0) return null; // 10^15 - 1
		while (d.scale > 0 && d.mantissa % 10 == 0) {
			d.mantissa = d.mantissa / 10;
			d.scale--;
		}
		d.negative = negative;
		return d;
	}

	// A decimal constant as Roslyn writes it: Decimal.Zero, One or MinusOne, the int32 or int64 constructor,
	// or the five-part constructor (lo, mid, hi, isNegative, scale).
	function pushDecimal(d:DecimalConst):Void {
		var dec = g.typeTokenOf(decimal);
		var m = d.mantissa;
		var signed = d.negative ? -m : m;
		var isInt = d.scale == 0 && m <= 0x7FFFFFFF;
		var v = signed.low;
		if (isInt && v >= -1 && v <= 1) {
			var name = v == 0 ? "Zero" : v == 1 ? "One" : "MinusOne";
			il.opToken(IlOps.LDSFLD, g.mb.memberRef(dec, name, g.sigs.field(decimal)), 0, 1);
		} else if (isInt) {
			il.ldcI4(v);
			il.opToken(IlOps.NEWOBJ, g.mb.memberRef(dec, ".ctor", g.sigs.method(true, LVoid, [LInt32], 0)), 1, 1);
		} else if (d.scale == 0) {
			il.opI64(IlOps.LDC_I8, signed, 0, 1);
			il.opToken(IlOps.NEWOBJ, g.mb.memberRef(dec, ".ctor", g.sigs.method(true, LVoid, [LInt64], 0)), 1, 1);
		} else {
			il.ldcI4(m.low);
			il.ldcI4(m.high);
			il.ldcI4(0);
			il.ldcI4(d.negative ? 1 : 0);
			il.ldcI4(d.scale);
			il.opToken(IlOps.NEWOBJ, g.mb.memberRef(dec, ".ctor", g.sigs.method(true, LVoid, [LInt32, LInt32, LInt32, LBool, LUInt8], 0)), 5, 1);
		}
	}

	// A static method of System.Decimal, called on the arguments on the stack.
	function decimalCall(name:String, ret:IlSigNorm, argSigs:Array<IlSigNorm>):Void {
		var token = g.mb.memberRef(g.typeTokenOf(decimal), name, g.sigs.method(false, ret, argSigs, 0));
		il.opToken(IlOps.CALL, token, argSigs.length, 1);
	}

	// ---- operators

	static function isNumber(s:Null<IlSigNorm>):Bool {
		return s != null && (s.match(LInt8 | LUInt8 | LInt16 | LUInt16 | LChar | LInt32 | LUInt32 | LInt64 | LUInt64 | LFloat32 | LFloat64) || isDecimal(s));
	}

	static function isString(s:Null<IlSigNorm>):Bool return s != null && s.match(LString);

	static function isUnsigned(s:IlSigNorm):Bool return s.match(LUInt32 | LUInt64);

	static function isFloat(s:IlSigNorm):Bool return s.match(LFloat32 | LFloat64);

	// The type C#'s binary numeric promotion computes `a` and `b` in, or null where C# has no operator. A
	// non-negative int literal goes with a uint or ulong operand as that type, as C# converts a constant.
	static function promote(a:IlSigNorm, b:IlSigNorm, aConst:Bool, bConst:Bool):Null<IlSigNorm> {
		if (isDecimal(a) || isDecimal(b)) return isFloat(a) || isFloat(b) ? null : decimal;
		if (a.match(LFloat64) || b.match(LFloat64)) return LFloat64;
		if (a.match(LFloat32) || b.match(LFloat32)) return LFloat32;
		inline function signed(s:IlSigNorm) return s.match(LInt8 | LInt16 | LInt32 | LInt64);
		if (a.match(LUInt64) || b.match(LUInt64)) {
			var other = a.match(LUInt64) ? b : a, otherConst = a.match(LUInt64) ? bConst : aConst;
			return signed(other) && !otherConst ? null : LUInt64;
		}
		if (a.match(LInt64) || b.match(LInt64)) return LInt64;
		if (a.match(LUInt32) || b.match(LUInt32)) {
			var other = a.match(LUInt32) ? b : a, otherConst = a.match(LUInt32) ? bConst : aConst;
			return signed(other) && !otherConst ? LInt64 : LUInt32;
		}
		return LInt32;
	}

	// A non-negative int literal, which converts to any integer type that holds it.
	static function isIntConstant(x:CsExpr):Bool {
		return switch (x.def) {
			case CParen(e1): isIntConstant(e1);
			case CLiteral(LInt(s)):
				var lit = intLiteral(s);
				lit != null && lit.t.match(LInt32);
			case _: false;
		}
	}

	// Converts the value under the one of type `top` on the stack with `convert`, `top` going through a
	// temporary meanwhile.
	function convertUnder(top:Null<IlSigNorm>, convert:Void->Void):Void {
		var tmp = il.addLocal(top == null ? LObject : top);
		il.stloc(tmp);
		convert();
		il.ldloc(tmp);
	}

	// The operands of types `ta` and `tb` on the stack, written `a` and `b`, converted to the type C#
	// computes `op` in, which this returns; refused where C# has no numeric operator for them.
	function numericOperands(op:String, a:CsExpr, b:CsExpr, ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		var t = isNumber(ta) && isNumber(tb) ? promote(ta, tb, isIntConstant(a), isIntConstant(b)) : null;
		if (t == null) operatorError(op, ta, tb);
		// A small integer and a uint are an int32 on the stack already.
		var same = IlPaths.sigEq(ta, t) || t.match(LInt32 | LUInt32) && ta.match(LInt8 | LUInt8 | LInt16 | LUInt16 | LChar | LInt32 | LUInt32);
		if (!same) convertUnder(tb, () -> explicitCast(ta, t));
		explicitCast(tb, t);
		return t;
	}

	function operatorError(op:String, a:Null<IlSigNorm>, b:Null<IlSigNorm>):Dynamic {
		return error("the inline C# operator " + op + " does not apply to " + article(csName(a)) + " and " + article(csName(b)) + " (C# error CS0019)");
	}

	// `a op b` but `&&` and `||`, with both operands pushed: `ta` and `tb` are their types.
	function binary(op:String, a:CsExpr, b:CsExpr, ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		return switch (op) {
			case "+" if (isString(ta) || isString(tb)): concat(ta, tb);
			case "==" | "!=": equality(op == "==", a, b, ta, tb);
			case "<" | ">" | "<=" | ">=": comparison(op, a, b, ta, tb);
			case _: arithmetic(op, a, b, ta, tb);
		}
	}

	function arithmetic(op:String, a:CsExpr, b:CsExpr, ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		var t = numericOperands(op, a, b, ta, tb);
		if (isDecimal(t)) {
			decimalCall(switch (op) {
				case "+": "op_Addition";
				case "-": "op_Subtraction";
				case "*": "op_Multiply";
				case "/": "op_Division";
				case _: "op_Modulus";
			}, decimal, [decimal, decimal]);
			return t;
		}
		var unsigned = isUnsigned(t);
		il.op(switch (op) {
			case "+": IlOps.ADD;
			case "-": IlOps.SUB;
			case "*": IlOps.MUL;
			case "/": unsigned ? IlOps.DIV_UN : IlOps.DIV;
			case _: unsigned ? IlOps.REM_UN : IlOps.REM;
		}, 2, 1);
		return t;
	}

	// C#'s string `+`: String.Concat of the two strings, or of both as objects when one is not a string.
	function concat(ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		var both = isString(ta) && isString(tb);
		if (!both) {
			if (ta != null && DotnetTypes.isValueType(ta) || ta != null && isTypeParam(ta)) convertUnder(tb, () -> box(ta));
			box(tb);
		}
		var argSig = both ? LString : LObject;
		il.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(LString), "Concat", g.sigs.method(false, LString, [argSig, argSig], 0)), 2, 1);
		return LString;
	}

	function comparison(op:String, a:CsExpr, b:CsExpr, ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		var t = numericOperands(op, a, b, ta, tb);
		if (isDecimal(t)) {
			decimalCall(switch (op) {
				case "<": "op_LessThan";
				case ">": "op_GreaterThan";
				case "<=": "op_LessThanOrEqual";
				case _: "op_GreaterThanOrEqual";
			}, LBool, [decimal, decimal]);
			return LBool;
		}
		// As Roslyn: `<=` is `!(a > b)` and `>=` is `!(a < b)`, unordered for doubles, so NaN compares false.
		var un = isUnsigned(t) || isFloat(t) && (op == "<=" || op == ">=");
		switch (op) {
			case "<": il.op(isUnsigned(t) ? IlOps.CLT_UN : IlOps.CLT, 2, 1);
			case ">": il.op(isUnsigned(t) ? IlOps.CGT_UN : IlOps.CGT, 2, 1);
			case "<=": il.op(un ? IlOps.CGT_UN : IlOps.CGT, 2, 1);
			case _: il.op(un ? IlOps.CLT_UN : IlOps.CLT, 2, 1);
		}
		if (op == "<=" || op == ">=") not();
		return LBool;
	}

	function not():Void {
		il.ldcI4(0);
		il.op(IlOps.CEQ, 2, 1);
	}

	// `==` and `!=`: numbers after promotion, two bools, two strings by value (String.op_Equality), other
	// references and null by identity.
	function equality(eq:Bool, a:CsExpr, b:CsExpr, ta:Null<IlSigNorm>, tb:Null<IlSigNorm>):IlSigNorm {
		var op = eq ? "==" : "!=";
		if (isNumber(ta) && isNumber(tb)) {
			var t = numericOperands(op, a, b, ta, tb);
			if (isDecimal(t)) {
				decimalCall(eq ? "op_Equality" : "op_Inequality", LBool, [decimal, decimal]);
				return LBool;
			}
			il.op(IlOps.CEQ, 2, 1);
		} else if (isString(ta) && isString(tb)) {
			var token = g.mb.memberRef(g.typeTokenOf(LString), eq ? "op_Equality" : "op_Inequality", g.sigs.method(false, LBool, [LString, LString], 0));
			il.opToken(IlOps.CALL, token, 2, 1);
			return LBool;
		} else if (ta != null && ta.match(LBool) && tb != null && tb.match(LBool) || (ta == null || isReference(ta)) && (tb == null || isReference(tb))) {
			il.op(IlOps.CEQ, 2, 1);
		} else {
			operatorError(op, ta, tb);
		}
		if (!eq) not();
		return LBool;
	}

	// Pushes `x`, which must be a bool.
	function boolOperand(x:CsExpr):Void {
		var t = value(x);
		if (t == null || !t.match(LBool))
			error("the inline C# expression is " + article(csName(t)) + ", which does not convert to bool implicitly (C# error CS0029)");
	}

	// `a && b` and `a || b`, which evaluate b only when a does not decide.
	function shortCircuit(isAnd:Bool, a:CsExpr, b:CsExpr):IlSigNorm {
		var decided = il.newLabel(), end = il.newLabel();
		boolOperand(a);
		il.branch(isAnd ? IlOps.BRFALSE : IlOps.BRTRUE, decided);
		boolOperand(b);
		il.branch(IlOps.BR, end);
		il.mark(decided);
		il.ldcI4(isAnd ? 0 : 1);
		il.mark(end);
		return LBool;
	}

	// Unary `-` with C#'s promotion: a small integer computes as an int, a uint as a long, and a ulong has
	// none. `-2147483648` and `-9223372036854775808` are int.MinValue and long.MinValue, as in C#.
	function negate(x:CsExpr):IlSigNorm {
		switch (x.def) {
			case CLiteral(LInt(s)):
				var lit = intLiteral(s);
				if (lit != null && lit.t.match(LUInt32) && lit.v == haxe.Int64.make(0, 0x80000000)) {
					il.ldcI4(0x80000000);
					return LInt32;
				}
				if (lit != null && lit.t.match(LUInt64) && lit.v == haxe.Int64.make(0x80000000, 0)) {
					il.opI64(IlOps.LDC_I8, lit.v, 0, 1);
					return LInt64;
				}
			case CLiteral(LReal(s)) if (StringTools.endsWith(s.toLowerCase(), "m")):
				var d = decimalConstant(x);
				if (d != null) {
					d.negative = !d.negative;
					pushDecimal(d);
					return decimal;
				}
			case _:
		}
		var t = value(x);
		if (t == null) return operatorError1("-", t);
		switch (t) {
			case LInt8 | LUInt8 | LInt16 | LUInt16 | LChar | LInt32:
				il.op(IlOps.NEG, 1, 1);
				return LInt32;
			case LUInt32:
				il.op(IlOps.CONV_U8, 1, 1);
				il.op(IlOps.NEG, 1, 1);
				return LInt64;
			case LInt64 | LFloat32 | LFloat64:
				il.op(IlOps.NEG, 1, 1);
				return t;
			case _ if (isDecimal(t)):
				decimalCall("op_UnaryNegation", decimal, [decimal]);
				return decimal;
			case _:
				return operatorError1("-", t);
		}
	}

	function operatorError1(op:String, t:Null<IlSigNorm>):Dynamic {
		return error("the inline C# operator " + op + " does not apply to " + article(csName(t)) + " (C# error CS0023)");
	}

	// ---- casts

	// `(to)x`. A decimal from a constant folds as Roslyn does (plan ruling 5).
	function castExpr(to:IlSigNorm, x:CsExpr):IlSigNorm {
		if (isDecimal(to)) {
			var d = decimalConstant(x);
			if (d != null) {
				pushDecimal(d);
				return to;
			}
		}
		explicitCast(value(x), to);
		return to;
	}

	// A value type on the stack boxed, as C# converts it to object.
	function box(s:Null<IlSigNorm>):Void {
		if (s != null && (DotnetTypes.isValueType(s) || isTypeParam(s))) il.opToken(IlOps.BOX, g.typeTokenOf(s), 1, 1);
	}

	// C#'s explicit (unchecked) conversion of the `from` on the stack to `to`: identity, between numbers
	// (decimal through its op_Implicit and op_Explicit), boxing, unboxing (unbox.any), and between references
	// an upcast or castclass.
	function explicitCast(from:Null<IlSigNorm>, to:IlSigNorm):Void {
		if (from == null) {
			if (DotnetTypes.isValueType(to)) error("the inline C# null does not convert to " + csName(to) + " (C# error CS0037)");
			return;
		}
		if (IlPaths.sigEq(from, to)) return;
		if (from.match(LVoid)) error("the inline C# expression has no value (C# error CS0029)");
		if (isDecimal(from) && isNumber(to)) {
			decimalCall("op_Explicit", to, [decimal]);
		} else if (isDecimal(to) && isNumber(from)) {
			decimalCall(isFloat(from) ? "op_Explicit" : "op_Implicit", decimal, [from]);
		} else if (isNumber(from) && isNumber(to)) {
			numericCast(from, to);
		} else if ((DotnetTypes.isValueType(from) || isTypeParam(from)) && (to.match(LObject) || isReference(to) && g.externs.implicitlyConverts(from, to))) {
			box(from);
		} else if ((DotnetTypes.isValueType(to) || isTypeParam(to)) && isReference(from)) {
			il.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
		} else if (isReference(from) && isReference(to)) {
			if (!g.isUpcast(from, to) && !to.match(LObject)) tl.castTo(to);
		} else {
			error("the inline C# expression is " + article(csName(from)) + ", which does not convert to " + csName(to) + " (C# error CS0030)");
		}
	}

	// C#'s unchecked conversion between the primitive numbers `from` and `to` (no decimal).
	function numericCast(from:IlSigNorm, to:IlSigNorm):Void {
		var unsignedFrom = from.match(LUInt8 | LUInt16 | LChar | LUInt32 | LUInt64);
		var from64 = from.match(LInt64 | LUInt64);
		var fromFloat = isFloat(from);
		inline function op(o:Int) il.op(o, 1, 1);
		switch (to) {
			case LInt8: op(IlOps.CONV_I1);
			case LUInt8: op(IlOps.CONV_U1);
			case LInt16: op(IlOps.CONV_I2);
			case LUInt16 | LChar: op(IlOps.CONV_U2);
			case LInt32: if (from64 || fromFloat) op(IlOps.CONV_I4);
			case LUInt32: if (from64 || fromFloat) op(IlOps.CONV_U4);
			case LInt64 | LUInt64:
				if (fromFloat) op(to.match(LInt64) ? IlOps.CONV_I8 : IlOps.CONV_U8);
				else if (!from64) op(unsignedFrom ? IlOps.CONV_U8 : IlOps.CONV_I8);
			case LFloat32 | LFloat64:
				if (from.match(LUInt32 | LUInt64)) op(IlOps.CONV_R_UN);
				op(to.match(LFloat32) ? IlOps.CONV_R4 : IlOps.CONV_R8);
			case _:
				throw "internal error: not a number: " + to;
		}
	}
}
