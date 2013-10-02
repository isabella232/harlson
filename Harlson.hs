module Harlson where

import Network.Socket
import Network.BSD

import Control.Exception
import Control.Concurrent
import Control.Concurrent.MVar

import Data.Time.Clock
import Data.Word
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.ByteString.Lazy as B
import qualified Data.Binary.Put as Put
import qualified Data.Binary.Get as Get

import System.IO
import System.Exit

import Options
import Mavg
import Server
import Query

data MData = MData { mdCounter :: Int
                   , mdLevel :: B.ByteString
                   } deriving Show

data OverLimit = OverLimit { oValue :: Int
                           , oThrottle :: Int
                           } deriving Show

data Metric = Metric { mMavg :: MVar Mavg
                     , mData :: MVar MData
                     }

data Key = Key { kKey :: B.ByteString
               , kEndpoint :: B.ByteString
               } deriving (Show, Eq, Ord)

data LKey = LKey { lkLevel :: B.ByteString
                 , lkEndpoint :: B.ByteString
                 } deriving (Show, Eq, Ord)

type MetricsMap = Map.Map Key Metric

type OverLimitsMap = Map.Map Key OverLimit

type LimitsMap = Map.Map LKey Int

data YState = YState { sMetrics :: MVar MetricsMap
                     , sOverLimits :: MVar OverLimitsMap -- the only modifier is mavgUpdater
                     , sLimits :: MVar LimitsMap
                     , sExit :: MVar Int
                     }

runHarlson opts = do
    mvMetrics <- newMVar Map.empty
    mvOverLimits <- newMVar Map.empty
    mvLimits <- newMVar Map.empty
    mvExit <- newEmptyMVar
    let ystate = YState mvMetrics mvOverLimits mvLimits mvExit
    let queryProcessor = processQuery opts ystate
    forkIO $ mavgUpdater ystate
    forkIO $ serveTCP (optPort opts) (handler queryProcessor)
    case optMode opts of
        ErlangPortMode -> do
            forkIO $ waitPortClose mvExit
            return ()
        StandaloneMode ->
            return ()
    exitCode <- takeMVar mvExit
    return ()

waitPortClose mvExit = do
    hSetBuffering stdin NoBuffering
    r <- try getChar :: IO (Either IOError Char)
    putMVar mvExit 0

mavgUpdater :: YState -> IO ()
mavgUpdater ystate = do
    threadDelay 1000000
    metrics <- readMVar (sMetrics ystate)
    limits <- readMVar (sLimits ystate)
    now <- getCurrentTime
    let ms = Map.toList metrics
    mapM_ (\(k@(Key _ ep), m)  -> do
        mavg <- readMVar (mMavg m)
        (c, lvl) <- modifyMVar (mData m) (\(MData c lvl) -> return $! (MData 0 lvl, (c, lvl)))
        let mavg' = bumpRate mavg now c
        let ra = rateAverage mavg'
        modifyMVar_ (sOverLimits ystate) (\overLimits -> do
            let limit = (Map.findWithDefault 2000000000 (LKey lvl ep) limits)
            if ra > limit
                then do
                    let limit_l = fromIntegral limit :: Integer
                    let ra_l = fromIntegral ra :: Integer
                    let p = fromIntegral (1000000 * limit_l `div` ra_l)
                    return $! Map.insert k (OverLimit ra p) overLimits
                else return $! Map.delete k overLimits)
        swapMVar (mMavg m) $! mavg') ms
    mavgUpdater ystate

handler :: (Handle -> Query -> IO ()) -> SockAddr -> Handle -> IO ()
handler qp sa h = do
    isEof <- hIsEOF h
    if isEof
        then hClose h
        else readQuery h >>= qp h >> handler qp sa h

processQuery :: Options -> YState -> Handle -> Query -> IO ()
processQuery opts ystate h (UpdateMetrics qms) = mapM_ (updateMetric (optSmoothing opts) (sMetrics ystate) h) qms
processQuery opts ystate h GetOverLimit = do
    let mvOverLimits = sOverLimits ystate
    overLimitsMap <- readMVar mvOverLimits
    let os = Map.toList overLimitsMap
    writeReply h $ ReplyOverLimit [ROverLimit k e (OverLimitAdded val thr) | (Key k e, OverLimit val thr) <- os]
processQuery opts ystate h (UpdateLimits qls) = do
    let mvLimits = sLimits ystate
    modifyMVar_ mvLimits (\limits -> do
        let limits' = Map.fromList [(LKey lvl ep, lim) | (QLimit lvl ep lim) <- qls]
        return limits')
processQuery opts ystate h Stop = putMVar (sExit ystate) 0

updateMetric :: Double -> MVar MetricsMap -> Handle -> QMetric -> IO ()
updateMetric smoothingWindow mvMetrics h (QMetric key ep lvl cnt) = do
    let k = Key key ep
    metric <- modifyMVar mvMetrics (\metrics ->
        case Map.lookup k metrics of
            Just m -> return $! (metrics, m)
            Nothing -> do
                m <- newMetric smoothingWindow
                return $! (Map.insert k m metrics, m))
    modifyMVar_ (mData metric) (\(MData c _) -> return $! MData (c + cnt) lvl)

newMetric :: Double -> IO Metric
newMetric smoothingWindow = do
    mavg <- mavgNewIO smoothingWindow
    ma <- newMVar mavg
    mc <- newMVar (MData 0 B.empty)
    return $ Metric ma mc