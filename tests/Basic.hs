{-# LANGUAGE RecordWildCards #-}
import Control.Applicative ((<$>))
import Control.Exception
import Data.Maybe (isNothing)
import System.Exit (exitFailure, exitSuccess)
import System.Timeout (timeout)
import Test.HUnit
import BroadcastChan
import BroadcastChan.Throw (BChanError(..))
import qualified BroadcastChan.Throw as Throw

labelTest :: String -> Assertion -> Test
labelTest name = TestLabel name . TestCase

expect :: (Eq e, Exception e) => e -> IO () -> Assertion
expect err act = do
    result <- try act
    case result of
        Left e | e == err -> return ()
               | otherwise -> assertFailure $
                                "Expected: " ++ show err ++ "\nGot: " ++ show e
        Right _ -> assertFailure $ "Expected exception, got success."

shouldn'tBlock :: IO a -> Assertion
shouldn'tBlock act = do
    result <- timeout 2000000 act
    case result of
        Nothing -> assertFailure "Shouldn't block!"
        Just _ -> return ()

isClosedNoBlock :: Test
isClosedNoBlock = labelTest "isClosedBChan doesn't block" $ do
    chan <- newBroadcastChan
    not <$> isClosedBChan chan @? "Shouldn't be closed."
    shouldn'tBlock $ isClosedBChan chan

readEmptyClosed :: Test
readEmptyClosed = labelTest "Read Empty Closed" $ do
    chan <- newBroadcastChan
    closeBChan chan
    listen <- newBChanListener chan
    isNothing <$> readBChan listen @? "Shouldn't read from empty channel!"

readEmptyClosedThrow :: Test
readEmptyClosedThrow = labelTest "Read Empty Closed Throw" $ do
    chan <- newBroadcastChan
    closeBChan chan
    listen <- newBChanListener chan
    expect ReadFailed $ Throw.readBChan listen

writeClosed :: Test
writeClosed = labelTest "Write Closed" $ do
    chan <- newBroadcastChan
    closeBChan chan
    not <$> writeBChan chan () @? "Shouldn't write to closed BroadcastChan"

writeClosedThrow :: Test
writeClosedThrow = labelTest "Write Closed Throw" $ do
    chan <- newBroadcastChan
    closeBChan chan
    expect WriteFailed $ Throw.writeBChan chan ()

tests :: [Test]
tests =
  [ isClosedNoBlock
  , readEmptyClosed
  , readEmptyClosedThrow
  , writeClosed
  , writeClosedThrow
  ]

main :: IO ()
main = do
    Counts{..} <- runTestTT $ TestList tests
    if errors > 0 || failures > 0
       then exitFailure
       else exitSuccess
