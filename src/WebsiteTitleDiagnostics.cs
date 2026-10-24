using System.Globalization;
using System.Text.RegularExpressions;

namespace Clipman
{
    internal sealed class WebsiteTitleDiagnostics
    {
        private long failures;
        private long staleResults;
        private string lastFailure = "None";

        public void RecordFailure(string error)
        {
            failures++;
            var status = Regex.Match(error ?? string.Empty, @"\bHTTP ([1-5][0-9]{2})\b");
            lastFailure = status.Success ? status.Value : "Title unavailable";
        }

        public void RecordStaleResult()
        {
            staleResults++;
        }

        public string Summary()
        {
            return string.Format(CultureInfo.InvariantCulture,
                "Automatic website titles: {0} failed; {1} changed entries skipped. Last failure: {2}.",
                failures, staleResults, lastFailure);
        }
    }
}
