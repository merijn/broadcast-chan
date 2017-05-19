import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Criterion.IO (readJSONReports)
import Criterion.Main (defaultConfig)
import Criterion.Monad (withConfig)
import Criterion.Report (report)
import Criterion.Types (Config(reportFile))

main :: IO ()
main = do
    args@(~(jsonFile:outputFile:_)) <- getArgs

    case args of
        [_,_] -> return ()
        _ -> do
            exe <- getProgName
            hPutStrLn stderr $ "Usage:"
            hPutStrLn stderr $ "  " ++ exe ++ " <input json> <output file>"
            exitFailure

    let config = defaultConfig { reportFile = Just outputFile }

    res <- readJSONReports jsonFile
    case res of
        Left err -> do
            hPutStrLn stderr $ "Error reading file: " ++ jsonFile
            hPutStrLn stderr $ "  " ++ show err
            exitFailure
        Right (_,_,rpts) -> withConfig config $ report rpts
