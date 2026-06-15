using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace Clipman
{
    internal static class JsonUtil
    {
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer
        {
            MaxJsonLength = int.MaxValue,
            RecursionLimit = 100
        };

        public static T Load<T>(string path) where T : new()
        {
            if (!File.Exists(path))
            {
                return new T();
            }

            var text = File.ReadAllText(path, Encoding.UTF8);
            if (string.IsNullOrWhiteSpace(text))
            {
                return new T();
            }

            var value = Serializer.Deserialize<T>(text);
            if (value == null)
            {
                return new T();
            }
            return value;
        }

        public static void SaveAtomic<T>(string path, T value)
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            var temp = path + ".tmp";
            var json = Serializer.Serialize(value);
            File.WriteAllText(temp, PrettyPrint(json), Encoding.UTF8);
            if (File.Exists(path))
            {
                File.Replace(temp, path, null);
            }
            else
            {
                File.Move(temp, path);
            }
        }

        public static string SerializePretty<T>(T value)
        {
            return PrettyPrint(Serializer.Serialize(value));
        }

        public static T Deserialize<T>(string text) where T : new()
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                return new T();
            }

            var value = Serializer.Deserialize<T>(text);
            return value == null ? new T() : value;
        }

        private static string PrettyPrint(string json)
        {
            var output = new StringBuilder();
            var indent = 0;
            var quoted = false;
            for (var i = 0; i < json.Length; i++)
            {
                var ch = json[i];
                if (ch == '"' && !IsEscaped(json, i))
                {
                    quoted = !quoted;
                }

                if (quoted)
                {
                    output.Append(ch);
                    continue;
                }

                switch (ch)
                {
                    case '{':
                    case '[':
                        output.Append(ch).AppendLine();
                        indent++;
                        output.Append(new string(' ', indent * 2));
                        break;
                    case '}':
                    case ']':
                        output.AppendLine();
                        indent--;
                        output.Append(new string(' ', indent * 2)).Append(ch);
                        break;
                    case ',':
                        output.Append(ch).AppendLine();
                        output.Append(new string(' ', indent * 2));
                        break;
                    case ':':
                        output.Append(": ");
                        break;
                    default:
                        output.Append(ch);
                        break;
                }
            }

            return output.ToString();
        }

        private static bool IsEscaped(string text, int index)
        {
            var slashCount = 0;
            for (var i = index - 1; i >= 0 && text[i] == '\\'; i--)
            {
                slashCount++;
            }
            return slashCount % 2 == 1;
        }
    }
}
