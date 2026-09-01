using System;

namespace Clipman
{
    internal sealed class StorageRetryResult
    {
        public bool Succeeded { get; private set; }
        public Exception Error { get; private set; }
        public Exception TextHistoryError { get; private set; }
        public Exception FileHistoryError { get; private set; }

        private StorageRetryResult(Exception textHistoryError, Exception fileHistoryError)
        {
            TextHistoryError = textHistoryError;
            FileHistoryError = fileHistoryError;
            Succeeded = textHistoryError == null && fileHistoryError == null;
            Error = textHistoryError ?? fileHistoryError;
        }

        public static StorageRetryResult Complete(Exception textHistoryError, Exception fileHistoryError)
        {
            return new StorageRetryResult(textHistoryError, fileHistoryError);
        }
    }

    internal static class StorageRetryOperation
    {
        public static StorageRetryResult Execute(Action reloadTextHistory, Action reloadFileHistory)
        {
            if (reloadTextHistory == null) throw new ArgumentNullException("reloadTextHistory");
            if (reloadFileHistory == null) throw new ArgumentNullException("reloadFileHistory");

            Exception textHistoryError = null;
            Exception fileHistoryError = null;
            try
            {
                reloadTextHistory();
            }
            catch (Exception ex)
            {
                textHistoryError = ex;
            }

            try
            {
                reloadFileHistory();
            }
            catch (Exception ex)
            {
                fileHistoryError = ex;
            }

            return StorageRetryResult.Complete(textHistoryError, fileHistoryError);
        }
    }
}
