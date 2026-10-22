// Rebuild: dotnet build -c Release, then copy bin/Release/netstandard2.0/Fixture.dll to tests/cases/net-lib/fixture/.
namespace Fixture {
	public class Plain {
		public Plain() {} public Plain(int x) {}
		public int Count; public readonly double Ratio; public static string Name = "p"; public const int Max = 10;
		public int Add(int a, int b) => a + b; public static long Wide(long v) => v;
		public byte[] Bytes() => null; public uint Unsigned() => 0; public object Any() => null;
	}
	internal class Hidden {}
	public class UsesLambda { public System.Func<int, int> F() => x => x + 1; }
}
namespace Fixture.Sub { public class Thing {} }
