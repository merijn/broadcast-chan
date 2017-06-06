{-# LANGUAGE NumDecimals #-}
{-# LANGUAGE ScopedTypeVariables #-}
module BroadcastChan.Test
    ( expect
    , doNothing
    , doPrint
    , fromTimeSpec
    , genStreamTests
    , runTests
    , withTime
    , MonadIO(..)
    , module Test.Tasty
    , module Test.Tasty.HUnit
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Exception (Exception, try)
import Data.Bifunctor (second)
import Data.Function (on)
import Data.List (sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Monoid ((<>))
import Data.Proxy (Proxy(Proxy))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Tagged (Tagged, untag)
import Data.Typeable (Typeable)
import Options.Applicative (switch, long, help)
import System.Clock (Clock(Monotonic), TimeSpec(..), diffTimeSpec, getTime)
import System.Environment (setEnv)
import System.IO (Handle, SeekMode(AbsoluteSeek), hPrint, hSeek)
import System.IO.Temp (withSystemTempFile)
import Test.Tasty
import Test.Tasty.Golden.Advanced (goldenTest)
import Test.Tasty.HUnit
import Test.Tasty.Options

import BroadcastChan.Helpers

expect :: (Eq e, Exception e) => e -> IO () -> Assertion
expect err act = do
    result <- try act
    case result of
        Left e | e == err -> return ()
               | otherwise -> assertFailure $
                                "Expected: " ++ show err ++ "\nGot: " ++ show e
        Right _ -> assertFailure $ "Expected exception, got success."

doNothing :: (Show a) => Int -> a -> IO a
doNothing threadPause x = do
    threadDelay threadPause
    return x

doPrint :: (Show a) => Handle -> a -> IO a
doPrint hnd x = do
    hPrint hnd x
    return x

fromTimeSpec :: Fractional n => TimeSpec -> n
fromTimeSpec = fromIntegral . nsec

speedupTest
    :: forall r . (Eq r, Show r)
    => IO (TVar (Map ([Int], Int) (MVar (r, Double))))
    -> ([Int] -> (Int -> IO Int) -> IO r)
    -> ([Int] -> (Int -> IO Int) -> Int -> IO r)
    -> Int
    -> [Int]
    -> Int
    -> String
    -> TestTree
speedupTest getCache seqSink parSink n inputs pause name = testCase name $ do
    withAsync cachedSequential $ \seqAsync ->
      withAsync (timed $ parSink inputs testFun n) $ \parAsync -> do
        (seqResult, seqTime) <- wait seqAsync
        (parResult, parTime) <- wait parAsync
        seqResult @=? parResult
        let lowerBound :: Double
            lowerBound = seqTime / (fromIntegral n + 1)

            upperBound :: Double
            upperBound = seqTime / (fromIntegral n - 1)

            errorMsg :: String
            errorMsg = mconcat
                [ "Parallel time should be 1/"
                , show n
                , "th of sequential time!\n"
                , "Actual time was 1/"
                , show (round $ seqTime / parTime :: Int)
                , "th (", show (seqTime/parTime), ")"
                ]
        assertBool errorMsg $ lowerBound < parTime && parTime < upperBound
  where
    testFun :: Int -> IO Int
    testFun = doNothing pause

    timed :: IO a -> IO (a, Double)
    timed = fmap (\(x, t) -> (x, fromTimeSpec t)) . withTime

    cachedSequential :: IO (r, Double)
    cachedSequential = do
        mvar <- newEmptyMVar
        cacheTVar <- getCache
        result <- atomically $ do
            cacheMap <- readTVar cacheTVar
            let (oldVal, newMap) = M.insertLookupWithKey
                    (\_ _ v -> v)
                    (inputs, pause)
                    mvar
                    cacheMap
            writeTVar cacheTVar newMap
            return oldVal

        case result of
            Just var -> readMVar var
            Nothing -> do
                timed (seqSink inputs testFun) >>= putMVar mvar
                readMVar mvar

outputTest
    :: forall r . (Eq r, Show r)
    => ([Int] -> (Int -> IO Int) -> IO r)
    -> ([Int] -> (Int -> IO Int) -> Int -> IO r)
    -> Int
    -> [Int]
    -> String
    -> TestTree
outputTest seqSink parSink threads inputs label =
    nonDeterministicGolden label seqTest parTest diff (const $ return ())
  where
    nonDeterministicGolden name =
      goldenTest name `on` fmap (second (T.strip . T.unlines . sort . T.lines))

    diff :: (r, Text) -> (r, Text) -> IO (Maybe String)
    diff (seqResult, seqOutput) (parResult, parOutput) =
        return $ resultDiff <> outputDiff
      where
        resultDiff :: Maybe String
        resultDiff
            | seqResult == parResult = Nothing
            | otherwise = Just "Results differ!\n"

        outputDiff :: Maybe String
        outputDiff
            | seqOutput == parOutput = Nothing
            | otherwise = Just . mconcat $
                [ "Outputs differ!\n"
                , "Expected:\n\"", T.unpack seqOutput, "\"\n\n"
                , "Got:\n\"", T.unpack parOutput, "\"\n"
                ]

    rewindAndRead :: Handle -> IO Text
    rewindAndRead hnd = do
        hSeek hnd AbsoluteSeek 0
        T.hGetContents hnd

    seqTest :: IO (r, Text)
    seqTest = withSystemTempFile "seq.out" $ \_ hndl ->
        (,) <$> seqSink inputs (doPrint hndl) <*> rewindAndRead hndl

    parTest :: IO (r, Text)
    parTest = withSystemTempFile "par.out" $ \_ hndl ->
        (,) <$> parSink inputs (doPrint hndl) threads <*> rewindAndRead hndl

newtype SlowTests = SlowTests Bool
  deriving (Eq, Ord, Typeable)

instance IsOption SlowTests where
  defaultValue = SlowTests False
  parseValue = fmap SlowTests . safeRead
  optionName = return "slow-tests"
  optionHelp = return "Run slow tests."
  optionCLParser =
    fmap SlowTests $
    switch
      (  long (untag (optionName :: Tagged SlowTests String))
      <> help (untag (optionHelp :: Tagged SlowTests String))
      )

genStreamTests
    :: (Eq r, Show r)
    => String
    -> ([Int] -> (Int -> IO Int) -> IO r)
    -> ([Int] -> (Int -> IO Int) -> Int -> IO r)
    -> TestTree
genStreamTests name f g = askOption $ \(SlowTests slow) ->
    withResource (newTVarIO M.empty) (const $ return ()) $ \getCache ->
    let
        testTree = buildTree testGroup
        params
          | slow = Param "threads" id [1,2,5,10]
                 . Param "inputs"  (enumFromTo 0) [60]
          | otherwise = Param "threads" id [1,2,5]
                      . Param "inputs"  (enumFromTo 0) [30]
        pause = Param "pause" id [1e6]

    in testGroup name
        [ testTree "output" (outputTest f g) $ params None
        , testTree "speedup" (speedupTest getCache f g) $ params . pause $ None
        ]

runTests :: String -> [TestTree] -> IO ()
runTests name tests = do
    setEnv "TASTY_NUM_THREADS" "100"
    defaultMainWithIngredients ingredients $ testGroup name tests
  where
    ingredients =
      includingOptions [Option (Proxy :: Proxy SlowTests)] : defaultIngredients

withTime :: IO a -> IO (a, TimeSpec)
withTime act = do
    start <- getTime Monotonic
    r <- act
    end <- getTime Monotonic
    return $ (r, diffTimeSpec start end)
