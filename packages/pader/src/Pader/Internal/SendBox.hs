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

module Pader.Internal.SendBox where


import           Control.Concurrent.MVar
import           Control.Exception (bracket)


type SendAck = IO ()
type ReceiveAck = IO ()


-- shutdown will be handled in TeleBox

newtype SendBox a = SendBox_ (MVar (a,SendAck))

newEmptySendBox :: IO (SendBox a)
newEmptySendBox = SendBox_ <$> newEmptyMVar

putSendBox :: SendBox a -> a -> IO ReceiveAck
putSendBox (SendBox_ !mv) !a = do
    !sync <- newEmptyMVar
    putMVar mv $! (a,) $! putMVar sync ()
    return $! takeMVar sync

putSendBox_ :: SendBox a -> a -> IO ()
putSendBox_ (SendBox_ !mv) !a = putMVar mv $! (a,return ())

openSendBox :: SendBox a -> (a -> IO b) -> IO b
openSendBox (SendBox_ !mv) !cont = bracket (takeMVar mv) (snd) (cont . fst)



