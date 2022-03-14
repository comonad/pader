
{-# LANGUAGE BangPatterns                     #-}
{-# LANGUAGE DeriveFunctor                    #-}
{-# LANGUAGE DerivingStrategies               #-}
{-# LANGUAGE DerivingVia                      #-}
{-# LANGUAGE FlexibleContexts                 #-}
{-# LANGUAGE FlexibleInstances                #-}
{-# LANGUAGE GADTs                            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving       #-}
{-# LANGUAGE KindSignatures                   #-}
{-# LANGUAGE MultiParamTypeClasses            #-}
{-# LANGUAGE RankNTypes                       #-}
{-# LANGUAGE ScopedTypeVariables              #-}
{-# LANGUAGE StandaloneDeriving               #-}
{-# LANGUAGE TupleSections                    #-}
{-# LANGUAGE ViewPatterns                     #-}

module Pader.Internal.TeleBox where


import           Pader.Internal.SendBox
import           Pader.Util.Watchdog
import           Control.Concurrent
import           Control.Concurrent.MVar
import           Control.Exception (evaluate,bracket,bracket_, finally)

import           Control.Monad
import           Control.Monad.Trans.Reader
import           Data.Foldable
import           Data.Function (fix)
import           Data.IORef
import           Data.IntMap.Strict as IntMap
import           Data.Maybe
import           Data.StateVar as StateVar
import           GHC.Base (sconcat,stimes,NonEmpty(..))

import           System.IO.Unsafe (unsafePerformIO)

import           System.Mem.Weak
import           Unsafe.Coerce (unsafeCoerce)


newtype TeleBoxSender a = TeleBoxSender (TeleBoxWire a)
newtype TeleBoxReceiver a = TeleBoxReceiver (TeleBoxWire a)

data TeleBoxWire a = TeleBoxWire_ !Watchdog !Leash !(MVar (Maybe (SendBox (Maybe a))))



send :: TeleBoxSender a -> a -> IO (ReceiveAck)
send tbx@(TeleBoxSender (TeleBoxWire_ wd l r)) !msg = keptAlive tbx $ do
    !aw<-isAlive tbx
    modifyMVar r $ \ !ms ->(ms,) <$> do
        case (aw,ms) of
            (True,Just sb) -> putSendBox sb (Just msg)
            (_,_) -> return (return ())

send_ :: TeleBoxSender a -> a -> IO ()
send_ tbx@(TeleBoxSender (TeleBoxWire_ wd l r)) !msg = keptAlive tbx $ do
    !aw<-isAlive tbx
    modifyMVar_ r $ \ !ms -> const ms <$> do
        case (aw,ms) of
            (True,Just sb) -> putSendBox_ sb (Just msg)
            (_,_) -> return ()

receive :: TeleBoxReceiver a -> (a -> IO b) -> IO b -> IO b
receive tbx@(TeleBoxReceiver (TeleBoxWire_ wd l r)) !listener !terminated = keptAlive tbx $ do
    !aw<-isAlive tbx
    modifyMVar r $ \ !ms -> (ms,) <$> do
        case (aw,ms) of
            (True,Just sb) -> do
                openSendBox sb $! maybe (putSendBox_ sb Nothing >> terminated) (listener)
            (_,_) -> terminated


createTeleBox :: forall a. IO (TeleBoxSender a,TeleBoxReceiver a)
createTeleBox = do
    !wds<-spawnWatchdog :: IO Watchdog
    !wdr<-spawnWatchdog :: IO Watchdog
    wds $= pure wdr
    wdr $= pure wds
    !sb<-newEmptySendBox :: IO (SendBox (Maybe a))
    !ms <- newMVar $ Just sb
    !mr <- newMVar $ Just sb
    let !tbs = TeleBoxSender (TeleBoxWire_ wds (leash wdr) ms)
    let !tbr = TeleBoxReceiver (TeleBoxWire_ wdr (leash wds) mr)
    onCleanup (leash wds) (hangup tbr >> hangup tbs)
    onCleanup (leash wdr) (hangup tbs >> hangup tbr)
    return (tbs,tbr)

class CanHangup telebox where
    hangup :: telebox -> IO ()
instance CanHangup (TeleBoxSender a) where
    hangup (TeleBoxSender (TeleBoxWire_ wd l r)) = do
        kill wd
        void $ forkIO $ modifyMVar_ r $ \ !ms -> do
            traverse_ `flip` ms $ \ !sb -> do
                putSendBox sb Nothing
            return Nothing
instance CanHangup (TeleBoxReceiver a) where
    hangup (TeleBoxReceiver (TeleBoxWire_ wd l r)) = do
        kill wd
        void $ forkIO $ modifyMVar_ r $ \ !ms -> do
            traverse_ `flip` ms $ \ !sb -> do
                forkIO $ fix $ \ !loop -> do
                    a<-openSendBox sb return
                    maybe (return()) (const loop) a
            return Nothing


instance IsAlive (TeleBoxSender a) where
    isAlive (TeleBoxSender w) = isAlive w
instance IsAlive (TeleBoxReceiver a) where
    isAlive (TeleBoxReceiver w) = isAlive w
instance IsAlive (TeleBoxWire a) where
    isAlive (TeleBoxWire_ wd l r) = (&&) <$> isAlive wd <*> isAlive l

instance KeepAlive (TeleBoxSender a) where
    watchdogs (TeleBoxSender w) = watchdogs w
instance KeepAlive (TeleBoxReceiver a) where
    watchdogs (TeleBoxReceiver w) = watchdogs w
instance KeepAlive (TeleBoxWire a) where
    watchdogs (TeleBoxWire_ wd l r) = pure wd

