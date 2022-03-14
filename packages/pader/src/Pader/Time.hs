{-# LANGUAGE BangPatterns   #-}
{-# LANGUAGE NamedFieldPuns #-}
module Pader.Time where


import Data.Time.Clock (UTCTime(..),UTCTime(utctDay,utctDayTime),nominalDiffTimeToSeconds,secondsToNominalDiffTime,DiffTime,NominalDiffTime)
import Data.Time.Clock.POSIX (getCurrentTime,getPOSIXTime, POSIXTime, posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Data.Time.Calendar (Day)
import Data.Time.Calendar.Julian (toJulian,fromJulian) --, Year, MonthOfYear, DayOfMonth)
import Data.Time.LocalTime (timeToTimeOfDay,timeOfDayToTime,TimeOfDay) --, DiffTime, TimeOfDay)

import Data.Time.Format (formatTime, defaultTimeLocale)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Fixed as Fixed

import Pader.Behavior(Behavior(..),Behavior(sample),attach)
import Pader.Event(Event(..),trigger,newEventWithWatchdogs,onEvent)
import Pader.Util.Watchdog(watchdogs,spawnWatchdog,onCleanup,leash,keepsAlive)

import System.IO.Unsafe (unsafePerformIO)
import Control.Concurrent (forkIO,threadDelay)
import Data.IORef (newIORef,atomicModifyIORef')
import Control.Concurrent.Chan.Split as Chan
import Control.Arrow (first)
import Control.Monad (when)

type Epoch = POSIXTime -- is in picos
type UTC = UTCTime -- wraps tuple of days and seconds

{-# NOINLINE timestampNow #-}
-- | strict and continuous growing timestamps (at least in picoseconds growing, which might happen when someone manipulates the system clock)
-- attach timestampNow :: Event a -> Event (Epoch,a)
timestampNow :: Behavior Epoch
timestampNow = unsafePerformIO $ do
    ref <- newIORef 0
    return $! Behavior $ do
        t<-getEpoch
        atomicModifyIORef' ref $ \t0 -> let t1 = max t (succ t0) in (t1, t1)

delay :: Pico -> Event a -> Event a
delay seconds = mapActor d . fmap (first $ addSeconds seconds) . attach timestampNow
    where
        d (t1,!a) = do
            t0 <- getEpoch
            let secondsToDelay = epochToSeconds t1 - epochToSeconds t0
            when (secondsToDelay > 0) $ do
                threadDelay $ ceiling $ secondsToDelay * 1000000 -- µs
            return a




addSeconds :: Pico -> Epoch -> Epoch
addSeconds seconds t = secondsToEpoch $ epochToSeconds t + seconds

-- | Event will be inserted into message queue, the actor will process one task at a time.
mapActor :: (a -> IO b) -> Event a -> Event b
mapActor f !ev = unsafePerformIO $! do
    (sendP,recvP) <- Chan.new
    let cleanup_chan = send sendP Nothing
    unreg_inserter <- onEvent ev (send sendP . Just)
    chanWriter_dog1 <- spawnWatchdog
    chanWriter_dog2 <- spawnWatchdog
    onCleanup (leash chanWriter_dog1) $ unreg_inserter >> cleanup_chan
    onCleanup (leash chanWriter_dog2) $ unreg_inserter >> cleanup_chan

    (!ev',!t') <- newEventWithWatchdogs $ watchdogs ev
    ev `keepsAlive` chanWriter_dog1
    ev' `keepsAlive` chanWriter_dog2

    let loop = do
            jx <- Chan.receive recvP
            maybe unreg_inserter `flip` jx $ \x -> do
                y <- f x
                ok <- trigger t' y
                if ok then loop else unreg_inserter

    forkIO loop
    return ev'


---


getUTC :: IO UTC
getUTC = getCurrentTime
utcToDateTime :: UTC -> ((Integer, Int, Int), TimeOfDay)
utcToDateTime UTCTime{utctDay,utctDayTime} = (toJulian utctDay,timeToTimeOfDay utctDayTime)
dateTimeToUtc :: ((Integer, Int, Int), TimeOfDay) -> UTC
dateTimeToUtc ((y,m,d),t) = UTCTime{utctDay=fromJulian y m d,utctDayTime = timeOfDayToTime t}

getEpoch :: IO Epoch
getEpoch = getPOSIXTime
epochToSeconds :: Epoch -> Pico
epochToSeconds = nominalDiffTimeToSeconds
secondsToEpoch :: Pico -> Epoch
secondsToEpoch = secondsToNominalDiffTime

epochToUtc :: Epoch -> UTC
epochToUtc = posixSecondsToUTCTime
utcToEpoch :: UTC -> Epoch
utcToEpoch = utcTimeToPOSIXSeconds

showUtcIso :: UTC -> String -- ^ "yyyy-mm-ddThh:mm:ss[.sss]Z"
showUtcIso = iso8601Show
showUtcPretty :: UTC -> String
showUtcPretty = formatTime defaultTimeLocale "%Y-%m-%d %a %H:%M:%S.%03ES %Z"

