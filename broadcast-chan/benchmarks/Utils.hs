import Prelude hiding (Foldable(..))
import Control.Concurrent
import Control.Monad (forM_)
import Data.List (foldl')
import GHC.Conc (getNumProcessors)

import BroadcastChan

main :: IO ()
main = do
    getNumProcessors >>= setNumCapabilities
    start <- newEmptyMVar
    done <- newEmptyMVar
    chan <- newBroadcastChan
    vals <- getBChanContents chan
    forkIO $ do
        putMVar start ()
        putMVar done $! foldl' (+) 0 vals
    readMVar start
    forM_ [1..10000 :: Int] $ writeBChan chan
    closeBChan chan
    takeMVar done >>= print
