import Control.Applicative ((<$>))
import Control.Monad (forM_)
import Data.Maybe (isNothing)
import System.Timeout (timeout)

import BroadcastChan
import BroadcastChan.Test
import BroadcastChan.Throw (BChanError(..))
import qualified BroadcastChan.Throw as Throw

lazyIO :: TestTree
lazyIO = testCase "getBChanContents" $ do
    chan <- newBroadcastChan
    result <- getBChanContents chan
    forM_ testData $ writeBChan chan
    closeBChan chan >>= assertBool "Channel should close"
    assertEqual "Data should be equal" testData result
  where
    testData :: [Int]
    testData = [1..10]

shouldn'tBlock :: IO a -> Assertion
shouldn'tBlock act = do
    result <- timeout 2000000 act
    case result of
        Nothing -> assertFailure "Shouldn't block!"
        Just _ -> return ()

isClosedNoBlock :: TestTree
isClosedNoBlock = testCase "isClosedBChan doesn't block" $ do
    chan <- newBroadcastChan
    not <$> isClosedBChan chan @? "Shouldn't be closed."
    shouldn'tBlock $ isClosedBChan chan

readEmptyClosed :: TestTree
readEmptyClosed = testCase "Read Empty Closed" $ do
    chan <- newBroadcastChan
    closeBChan chan
    listen <- newBChanListener chan
    isNothing <$> readBChan listen @? "Shouldn't read from empty channel!"

readEmptyClosedThrow :: TestTree
readEmptyClosedThrow = testCase "Read Empty Closed Throw" $ do
    chan <- newBroadcastChan
    closeBChan chan
    listen <- newBChanListener chan
    expect ReadFailed $ Throw.readBChan listen

writeClosed :: TestTree
writeClosed = testCase "Write Closed" $ do
    chan <- newBroadcastChan
    closeBChan chan
    not <$> writeBChan chan () @? "Shouldn't write to closed BroadcastChan"

writeClosedThrow :: TestTree
writeClosedThrow = testCase "Write Closed Throw" $ do
    chan <- newBroadcastChan
    closeBChan chan
    expect WriteFailed $ Throw.writeBChan chan ()

main :: IO ()
main = runTests "basic"
  [ lazyIO
  , isClosedNoBlock
  , readEmptyClosed
  , readEmptyClosedThrow
  , writeClosed
  , writeClosedThrow
  ]
