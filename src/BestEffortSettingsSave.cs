using System;
using System.IO;

namespace Clipman
{
    internal static class BestEffortSettingsSave
    {
        public static bool Try(Action save, Action<Exception> onFailure)
        {
            try
            {
                save();
                return true;
            }
            catch (IOException ex)
            {
                if (onFailure != null) onFailure(ex);
                return false;
            }
            catch (UnauthorizedAccessException ex)
            {
                if (onFailure != null) onFailure(ex);
                return false;
            }
        }
    }
}
