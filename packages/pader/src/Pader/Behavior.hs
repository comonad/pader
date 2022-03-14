{-# LANGUAGE BangPatterns                    #-}
{-# LANGUAGE DeriveFunctor                   #-}
{-# LANGUAGE DerivingStrategies              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving      #-}
{-# LANGUAGE NamedFieldPuns                  #-}
{-# LANGUAGE RankNTypes                      #-}
{-# LANGUAGE RecursiveDo                     #-}
{-# LANGUAGE StandaloneDeriving              #-}


module Pader.Behavior (
    Behavior(..),
    Dynamic(..),
    Accumulative(..),
    tag,attach,attachWith
) where

import Pader.Event
import Pader.Util.Watchdog
import Control.Monad (join)
import Data.Either (fromRight)
import Data.IORef (atomicModifyIORef, mkWeakIORef, newIORef, readIORef, writeIORef)
import Data.IORef.Extra (atomicModifyIORef_)
import System.IO.Unsafe (unsafePerformIO)
import System.Mem.Weak (deRefWeak)

import GHC.Base (sconcat,stimes)




newtype Behavior a = Behavior { sample :: IO a }
    deriving newtype (Functor,Applicative,Monad)

-- | at the updated event, current still contains the old value.
data Dynamic a = Dynamic { current :: !(Behavior a), updated :: !(Event a) }
    deriving (Functor)

instance Semigroup a => Semigroup (Dynamic a) where
    (<>) ma mb = let el = attachWith (flip (<>)) (current mb) (updated ma)
                     er = attachWith (<>) (current ma) (updated mb)
                  in unsafePerformIO $ updatedBehavior (current ma<>current mb) (el<>er)
    sconcat l = sconcat <$> sequence l

instance Monoid a => Monoid (Dynamic a) where
    mempty = pure mempty
    mconcat l = mconcat <$> sequence l

instance Semigroup a => Semigroup (Behavior a) where
    (<>) ma mb = do
        a<-ma
        b<-mb
        pure $ a<>b
    sconcat l = sconcat <$> sequence l
instance Monoid a => Monoid (Behavior a) where
    mempty = pure mempty
    mconcat l = mconcat <$> sequence l


tag :: Behavior b -> Event a -> Event b
tag = attachWith const

attach :: Behavior b -> Event a -> Event (b,a)
attach = attachWith (,)

attachWith :: (b->a->c) -> Behavior b -> Event a -> Event c
attachWith !f !bb !ea = unsafePerformIO $! do
    (!eb,!tb)<-newEvent
    eb `shouldAlsoKeepAlive` ea
    onEventWhile ea $ \ !a -> do
        !b<-sample bb
        trigger tb $! f b a
    return eb



class Accumulative f where
    -- | accum needs to run in IO: accum could collect the history of events, so we need to know when it was started.
    accum :: b -> (a->b->b) -> Event a -> IO (f b)

instance Accumulative Event where
    accum b f = let dup !x = (x,x) in mapAccumEvent b (\a b->dup $! f a b)

instance Accumulative Behavior where
    accum b0 f ev = do
        r<-newIORef b0
        unreg<-newIORef (return ()::UnregisterIO)
        w<-mkWeakIORef r $! join $ readIORef unreg
        unregister<-onEventWhile ev $ \ !a -> do
            mr<-deRefWeak w
            case mr of
                Just r -> atomicModifyIORef_ r (f a) >> keepAlive ev >> return True
                Nothing -> return False
        writeIORef unreg unregister
        return $! Behavior $! readIORef r

instance Accumulative Dynamic where
    --    accum s0 f ev = do
    --        updated<-accum s0 f ev
    --        current<-accum s0 const updated -- todo: keep old value in current
    --        return Dynamic{current,updated}
    accum b0 f ev = do
        !updated0<-accum b0 f ev
        !r<-newIORef b0
        (!updated,!t) <- newEvent
        updated `shouldAlsoKeepAlive` updated0
        !curWD <- spawnWatchdog
        curWD `shouldAlsoKeepAlive` updated
        !w <- mkWeakIORef r $ kill curWD
        _ <- onEventWhile updated0 $ \ !b -> do
            !ok1<-trigger t b
            mr<-deRefWeak w
            case mr of
                Just r -> atomicModifyIORef_ r (const b) >> return True
                Nothing -> return ok1
        return Dynamic{current = Behavior $ readIORef r,updated}

instance Applicative Dynamic where
    pure !a = Dynamic{current=pure a,updated=neverEvent}
    (<*>) Dynamic{current=c_ab,updated=u_ab} Dynamic{current=c_a,updated=u_a} = unsafePerformIO $ do
            let c_b = c_ab <*> c_a
                u_b1 = attachWith (flip id) (c_a) (u_ab)
                u_b2 = attachWith (id) (c_ab) (u_a)
                u_b = u_b1 <> u_b2
            updatedBehavior c_b u_b

updatedBehavior :: Behavior a -> Event a -> IO (Dynamic a)
updatedBehavior !b !e = do
            rec r <-  newIORef $! do
                    !x <- sample b
                    writeIORef r $! return x
                    return x
            let b' = Behavior $ join $ readIORef r
            !d<-accum (Left b') (const) $ Right <$> e
            return $ Dynamic
                { current=Behavior(sample (current d) >>= either sample pure)
                , updated=either undefined id <$> updated d
                }

instance Monad Dynamic where
    (>>=) ma a_mb = unsafePerformIO $ do
        let !ddb = a_mb <$> ma
            !c_b = current ddb >>= current
        !u_b <- switch $ updated <$> updated ddb
        updatedBehavior c_b u_b

