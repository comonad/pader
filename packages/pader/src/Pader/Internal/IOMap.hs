
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

module Pader.Internal.IOMap where


import           Control.Concurrent
import           Control.Concurrent.MVar
import           Control.Exception (evaluate,bracket,bracket_)
import           Data.IntMap.Strict as IntMap

import GHC.Base (sconcat,stimes,NonEmpty(..))


type UnregisterIO = IO ()


newtype IOMap a = IOMap_ (MVar (Int,IntMap a))
newIOMap :: IO (IOMap a)
newIOMap = IOMap_ <$> newMVar (0,IntMap.empty)
registerIOMap :: a -> IOMap a -> IO (UnregisterIO)
registerIOMap !a !(IOMap_ !mv) = do
    (!n,!m)<-takeMVar mv
    let findnextemptyindex !i =
            case IntMap.lookup i m of
                Nothing -> i
                Just _ -> findnextemptyindex $! i+1
        !n' = findnextemptyindex n
    putMVar mv $! ((,) $! (n'+1)) $! IntMap.insert n' a m
    return $! modifyMVar_ mv $ \(!n,!m) -> evaluate $! (n,) $! IntMap.delete n' m
clearIOMap :: IOMap a -> IO ()
clearIOMap (IOMap_ !mv) = modifyMVar_ mv $ \(!n,_) -> evaluate $! (n,IntMap.empty)
iterateIOMap :: IOMap a -> IO [a]
iterateIOMap (IOMap_ !mv) = IntMap.elems . snd <$> readMVar mv


