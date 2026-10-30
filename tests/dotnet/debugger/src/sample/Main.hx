package sample;

class Main {
	static function main() {
		var shapes = new Shapes(2);
		var total = 0;
		var count = 3;
		for (i in 0...count) {
			var side = i + 1;
			total += shapes.area(side);
		}
		trace("total " + total);
		{
			var inner = total * 2;
			trace("inner " + inner);
		}
		var offset = 10;
		var add = function(x:Int) return x + offset;
		trace("closure " + add(5));
		try {
			shapes.fail(3);
		} catch (e:String) {
			trace("caught " + e);
		}
		trace("field " + Reflect.field({answer: 42}, "answer"));
		var mapped = [1, 2].map(x -> x + 1);
		trace("mapped " + mapped);
	}
}
