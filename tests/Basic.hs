{-# LANGUAGE RecordWildCards #-}
import Control.Applicative ((<$>))
import Control.Exception
import Data.Maybe (isNothing)
import System.Exit (exitFailure, exitSuccess)
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
  [ readEmptyClosed
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
