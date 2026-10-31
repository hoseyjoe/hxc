// Shapes for milestone 4a's members area. netstandard2.0 so Haxe 4.3.7's net-lib reads it.
using System;
using System.Collections.Generic;
namespace M4 {
	// 1. interface properties (IChatHandler's shape: get-only string properties, plus a method)
	public interface IHandler {
		string Guid { get; }
		string Prompt { get; }
		List<string> Plugins();
	}
	public interface ICounter {
		int Count { get; set; }
		string Label { get; }
	}
	public interface IWriteOnly { int Sink { set; } }
	public static class PropReader {
		public static string Describe(IHandler h) => h.Guid + "|" + h.Prompt;
	}
	// a .NET base class's property implementing an interface property that a Haxe subclass lists (non-virtual and virtual)
	public interface INamed { string Name { get; } }
	public class BaseN { public string Name => "base"; }
	public class BaseV { public virtual string Name => "basev"; }
	public static class Names { public static string Read(INamed n) => n.Name; }
	public interface IGreet { string Greet(string who); }
	public class BaseGN { public string Greet(string who) => "basegn " + who; }
	public class BaseGV { public virtual string Greet(string who) => "basegv " + who; }
	public static class Greets { public static string Call(IGreet g) => g.Greet("x"); }
	public static class UseProps {
		public static string Read(IHandler h) => h.Guid + "/" + h.Prompt + "/" + h.Plugins().Count;
		public static string Bump(ICounter c) { c.Count = c.Count + 1; return c.Label + "=" + c.Count; }
		public static string Shape(Type t) {
			var s = new List<string>();
			foreach (var p in t.GetProperties(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.DeclaredOnly))
				s.Add("prop " + p.Name + (p.GetMethod != null ? " get" : "") + (p.SetMethod != null ? " set" : ""));
			return string.Join(", ", s);
		}
	}
	// 2. generic methods: overloads where a generic one precedes the non-generic one (NHibernate's ISession/IMultiQuery order)
	public interface ISess {
		string Make<T>() where T : class;
		string Make<T>(string alias) where T : class;
		string Make(Type t);
		string Make(string entityName);
		ICrit Crit(string entityName);
		T Get<T>(object id);
		IMulti Multi();
	}
	public interface ICrit {
		System.Collections.IList List();
		IList<T> List<T>();
		T Unique<T>();
		object Unique();
	}
	// two generic overloads
	public static class Picks {
		public static string Pick<T>(int id) => "Pick<" + Sess.Name(typeof(T)) + ">(int)";
		public static string Pick<T>(string s) => "Pick<" + Sess.Name(typeof(T)) + ">(string)";
		public static T Make<T>(T x, int n) => x;
		public static T Make<T>(T x, string s) => x;
	}
	// ICrit's overloads in the other metadata order
	public interface ICrit2 {
		IList<T> List<T>();
		System.Collections.IList List();
	}
	public class Crit2 : ICrit2 {
		public IList<T> List<T>() { Console.WriteLine("List<" + Sess.Name(typeof(T)) + ">()"); return new List<T>(); }
		public System.Collections.IList List() { Console.WriteLine("List()"); return new System.Collections.ArrayList { 1, 2 }; }
	}
	public interface IMulti {
		IMulti Add(Type t, string q);
		IMulti Add<T>(string q);
		IMulti Add<T>(string key, string q);
		IMulti Add(string q);
		int Count { get; }
	}
	public class Rec { public string Name; public Rec(string n) { Name = n; } public override string ToString() => "Rec(" + Name + ")"; }
	public class Sess : ISess, ICrit, IMulti {
		List<string> log = new List<string>();
		public string Make<T>() where T : class => "Make<" + typeof(T).Name + ">()";
		public string Make<T>(string alias) where T : class => "Make<" + typeof(T).Name + ">(" + alias + ")";
		public string Make(Type t) => "Make(Type " + t.Name + ")";
		public string Make(string entityName) => "Make(" + entityName + ")";
		public ICrit Crit(string entityName) => this;
		public T Get<T>(object id) { Console.WriteLine("Get<" + Name(typeof(T)) + ">(" + id + ")"); return default(T); }
		public IMulti Multi() => this;
		public System.Collections.IList List() { Console.WriteLine("List()"); return new System.Collections.ArrayList { 1, 2 }; }
		public IList<T> List<T>() { Console.WriteLine("List<" + Name(typeof(T)) + ">()"); return new List<T>(); }
		public T Unique<T>() { Console.WriteLine("Unique<" + Name(typeof(T)) + ">()"); return default(T); }
		public object Unique() { Console.WriteLine("Unique()"); return null; }
		public IMulti Add(Type t, string q) { log.Add("Add(Type,q)"); return this; }
		public IMulti Add<T>(string q) { log.Add("Add<" + Name(typeof(T)) + ">(" + q + ")"); return this; }
		public IMulti Add<T>(string key, string q) { log.Add("Add<" + Name(typeof(T)) + ">(key,q)"); return this; }
		public IMulti Add(string q) { log.Add("Add(" + q + ")"); return this; }
		public int Count => log.Count;
		public string Log => string.Join(" ", log);
		public static string Name(Type t) => t.IsGenericType ? t.Name + "[" + string.Join(",", Array.ConvertAll(t.GetGenericArguments(), Name)) + "]" : t.FullName ?? t.Name;
	}
	public interface IPing { string Ping(); }
	public interface IPingMore : IPing { string More(); }
	public interface IFiles { void OnFiles(string[] paths); }
	public static class Dialogs { public static void Open(IFiles l) { l.OnFiles(new[] { "a.txt", "b.txt" }); } }
}
