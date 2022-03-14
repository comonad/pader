{-# LANGUAGE DeriveFunctor                    #-}
{-# LANGUAGE DerivingStrategies               #-}
{-# LANGUAGE DerivingVia                      #-}
{-# LANGUAGE FlexibleContexts                 #-}
{-# LANGUAGE GADTs                            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving       #-}
{-# LANGUAGE KindSignatures                   #-}
{-# LANGUAGE RankNTypes                       #-}
{-# LANGUAGE ScopedTypeVariables              #-}
{-# LANGUAGE StandaloneDeriving               #-}
{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE TupleSections               #-}


module Pader.Event (
--    KeepAlive(..),IsAlive(..),
    Event,newEvent,onEvent,onEventOnce,
    Trigger,trigger,
    Listener(..),listenOnEvent,
    mapAccumEvent,onEventWhile,neverEvent,
    Pader.Event.union,switch,mapMaybeEvent,filterEvent,sequenceEvent,
    takeEvent,dropEvent,copyEvent,pipeEvent,
    UnregisterIO, OK,
    shouldAlsoKeepAlive,keepAlive,keptAlive
) where


import Pader.Internal.IOMap
import Pader.Internal.TeleBox
import Pader.Util.Watchdog
import Pader.Util.Bag
import Control.Concurrent
import Control.Concurrent.MVar

import Control.Exception (evaluate,bracket,bracket_, finally)
import Control.Monad
import Control.Monad.Trans.Reader
import Data.Foldable
import Data.IORef
import Data.IntMap.Strict as IntMap
import Data.Maybe

import GHC.Base (sconcat,stimes,NonEmpty(..))

import System.IO.Unsafe (unsafePerformIO)
import System.Mem.Weak



{-

import System.Mem

(e,t::Trigger String)<-newEvent
trigger t "hi"
let e = ()
-- sadly this does not GC
trigger t "hi"
performMajorGC
-- still true, broken only in ghci, to be ignored
trigger t "hi"


t<-do{(e,t::Trigger String)<-newEvent;Pader.onEvent e putStrLn;Pader.onEvent e putStrLn;return t}
trigger t "hi"
performMajorGC
-- true, OK
trigger t "hi"


(_,t::Trigger String)<-newEvent
trigger t "hi"
performMinorGC
-- false, OK
trigger t "hi"

-}


type OK = Bool


instance KeepAlive (Event a) where
    watchdogs (Registrable_ wd l _ _ ) = pure wd
    watchdogs _ = mempty
instance KeepAlive (Trigger a) where
    watchdogs (Trigger_ (wd::Watchdog) (l::Leash) (sem::MVar ()) (iom::(IOMap (TeleBoxSender a)))) = pure wd

instance IsAlive (Trigger a) where
    isAlive (Trigger_ (wd::Watchdog) (l::Leash) (sem::MVar ()) (iom::(IOMap (TeleBoxSender a)))) = (&&) <$> isAlive wd <*> isAlive l
instance IsAlive (Event a) where
    isAlive Never_ = return False
    isAlive (Registrable_ (wd::Watchdog) (l::Leash) (iom::(IOMap (TeleBoxSender x))) xa) = (&&) <$> isAlive wd <*> isAlive l





data Trigger a = Trigger_ !Watchdog !Leash !(MVar ()) !(IOMap (TeleBoxSender a)) -- leash solves cleanup when there is no event anymore
data Event a = Never_
             | forall x. Registrable_ !Watchdog !Leash !(IOMap (TeleBoxSender x)) !(x->Maybe a)


data Distribute = Sequential | Parallel !Synchronization
data Synchronization = Async | Sync

triggerD :: Distribute -> Trigger a -> a -> IO OK -- returns "still valid?"
triggerD dis trig@(Trigger_ (wd::Watchdog) (l::Leash) (sem::MVar()) (iom::(IOMap (TeleBoxSender a)))) a = do
    bracket_ (takeMVar sem) (putMVar sem ()) $ do
        b <- isAlive trig
        if b
            then do
                boxes <- iterateIOMap iom
                case dis of
                    Sequential -> do
                        traverse_ (join . (`send` a)) boxes
                    Parallel Sync -> do
                        syncs<-traverse (`send` a) boxes
                        sequence_ syncs
                    Parallel Async -> do
                        traverse_ (`send_` a) boxes
                keepAlive trig
            else do
                clearIOMap iom
        return b

trigger :: Trigger a -> a -> IO OK -- returns "still valid?"
trigger = triggerD $ Parallel Sync

neverEvent :: Event a
neverEvent = Never_


-- | Events need to be kept alive either by those Events they are wired to trigger
--
-- > created_event `shouldAlsoKeepAlive` event_that_triggers_it
--
-- or by `keepAlive`, `keptAlive`, see module Watchdog.
newEvent :: IO (Event a,Trigger a)
newEvent = do
    m <- newIOMap
    twd <- spawnWatchdog -- watching the trigger
    ewd <- spawnWatchdog -- watching the event
    let !e = Registrable_ ewd (leash twd) m Just
    sem <- newMVar ()
    let !t = Trigger_ (twd::Watchdog) (leash ewd) sem m -- TODO: cleanup when trigger is gone.
    return (e,t)



newtype Listener a = Listener {runListener :: a -> IO (Maybe (Listener a))}
feedListener :: Listener a -> [a] -> IO (Maybe (Listener a))
feedListener prog [] = return $ Just prog
feedListener (Listener f) (a:as) = f a >>= maybe (return Nothing) (`feedListener` as)


listenOnSendBox :: forall x a . TeleBoxReceiver x -> (x -> Maybe a) -> Listener a -> IO ()
listenOnSendBox box fa li@(Listener f) = do
            let prog :: x -> IO(Maybe(Listener a))
                prog x = case fa x of
                            Just a -> f a
                            Nothing -> return $ Just li
            maybeCont <- receive box prog (return Nothing)
            traverse_ (listenOnSendBox box fa) maybeCont

-- does not run "keepAlive e"
listenOnEvent :: Event a -> Listener a -> IO (UnregisterIO)
listenOnEvent Never_ _ = return (return ())
listenOnEvent e@(Registrable_ _ _ (iom::(IOMap (TeleBoxSender x))) fa) prog = do
    b <- isAlive e
    if b
    then do
        (tbs,tbr)<-createTeleBox :: IO (TeleBoxSender x,TeleBoxReceiver x)
        unregister <- registerIOMap tbs iom
        let loop (Listener f) = listenOnSendBox tbr fa $ Listener $ \a->do
                    maybeCont<-f a
                    when (isNothing maybeCont) unregister
                    return maybeCont
        forkIO $ loop prog
        return unregister
    else do
        return (return())

registerOnEvent :: Event a -> TeleBoxSender a -> IO (UnregisterIO)
registerOnEvent e box = onEventWhile e $ \a -> do
    rack<-send box a
    rack
    return True



-- does not run "keepAlive e"
onEventWhile :: Event a -> (a -> IO Bool) -> IO (UnregisterIO)
onEventWhile e f = listenOnEvent e l
    where
        l = Listener $ \a -> do
            b<-f a
            return $ if b then Just l else Nothing


sequenceEvent :: Event (IO a) -> IO (Event a)
sequenceEvent ev = do
    (!e,!t) <- newEvent
    e `shouldAlsoKeepAlive` ev
    _ <- onEventWhile ev $ \ioa -> do
        a<-ioa
        trigger t a
    return e

performEvent :: Event (IO Bool) -> IO (UnregisterIO)
performEvent ev = onEventWhile ev $ \ioa -> ioa `finally` keepAlive ev

onEvent :: Event a -> (a -> IO ()) -> IO (UnregisterIO)
onEvent e f = performEvent $ (\a->f a >> return True) <$> e

onEventOnce :: Event a -> (a -> IO ()) -> IO (UnregisterIO)
onEventOnce e f = performEvent $ (\a->f a >> return False) <$> e

takeEvent :: forall a. Event a -> Int -> IO (Event a)
takeEvent !ev !n
    | n<1 = return neverEvent
    | otherwise = do
        (!ev',!t') <- newEvent
        wd <- spawnWatchdog
        ev' `shouldAlsoKeepAlive` wd
        wd `protectsOnly` ev
        let copy :: Int -> Listener a
            copy n = Listener $ \ !a -> do
                ok<-trigger t' a
                if ok && (n>1) then
                    return $ Just (copy $! n-1)
                else do
                    wd `protectsOnly` ()
                    return Nothing
        _ <- listenOnEvent ev (copy n) :: IO (UnregisterIO)
        return ev'
dropEvent :: forall a. Event a -> Int -> IO (Event a)
dropEvent !ev !n
    | n<1 = return ev
    | otherwise = do
        (!ev',!t') <- newEvent
        ev' `shouldAlsoKeepAlive` ev
        let copyForever :: Listener a
            copyForever = Listener $ \ !a -> do
                ok<-trigger t' a
                return $ guard (ok) >> Just copyForever
        let copyAfter :: Int -> Listener a
            copyAfter n | n<=0 = copyForever
            copyAfter n = Listener $ \ !a -> do
                return $ guard (n>1) >> Just (copyAfter $! n-1)
        _ <- listenOnEvent ev (copyAfter n) :: IO (UnregisterIO)
        return ev'

-- | does not run `keepAlive e`
pipeEvent :: Event a -> Trigger a -> IO ()
pipeEvent !ev !t = do
        --_ <- onEventWhile ev (\msg->trigger t msg `finally` keepAlive ev) :: IO (UnregisterIO)
        _ <- onEventWhile ev (trigger t) :: IO (UnregisterIO)
        return ()

copyEvent :: Event a -> Event a
copyEvent !ev = unsafePerformIO $! do
        (!ev',!t') <- newEvent
        ev' `shouldAlsoKeepAlive` ev
        pipeEvent ev t'
        return ev'

mapMaybeEvent :: (a->Maybe b) -> Event a -> Event b
mapMaybeEvent f Never_ = Never_
mapMaybeEvent f (Registrable_ wd l m xa) = Registrable_ wd l m $! f <=< xa

filterEvent :: (a->Bool) -> Event a -> Event a
filterEvent p = mapMaybeEvent (\a->if p a then Just a else Nothing)

instance Functor Event where
    fmap f Never_ = Never_
    fmap f (Registrable_ wd l m xa) = Registrable_ wd l m $! fmap f . xa

instance Semigroup (Event a) where
    (<>) a b = mconcat [a,b]
    sconcat (a:|bs) = mconcat (a:bs)
    stimes 0 _ = neverEvent
    stimes 1 ev = ev
    stimes n ev = unsafePerformIO $! do
        (!e,!t)<-newEvent
        e `shouldAlsoKeepAlive` ev
        let tr 1 a = trigger t a
            tr n a = do
                b<-trigger t a
                if b then tr (n-1) a else return False
        _ <- onEventWhile ev (tr n) :: IO (UnregisterIO)
        return e
instance Monoid (Event a) where
    mempty = neverEvent
    mappend = (<>)
    mconcat [] = mempty
    mconcat [a] = a
    mconcat as = unsafePerformIO $! do
        (!e,!t)<-newEvent
        e `shouldAlsoKeepAlive` as
        traverse_ (`pipeEvent` t) as
        return e



-- | mapAccumEvent needs to run in IO: mapAccumEvent could collect the history of events, so we need to know when it was started.
mapAccumEvent :: s -> (a->s->(b,s)) -> Event a -> IO (Event b)
mapAccumEvent !s0 !f !evA = do
        (evB,t)<-newEvent
        evB `shouldAlsoKeepAlive` evA
        let loop s = Listener $ \a -> do
                    let (!b,!s') = f a s
                    trigger t $! b
                    return . Just . loop $! s'
        listenOnEvent evA (loop s0)
        return evB


-- | union needs to run in IO: union depends on the history of outer events that select the inner events, so we need to know when it was started.
union :: Event (Event a) -> IO (Event a)
union !evev = do
    wd<-spawnWatchdog
    (!ev_,!t)<-newEvent
    ev_ `shouldAlsoKeepAlive` wd
    ev_ `shouldAlsoKeepAlive` evev
    needsWashRef<-newIORef False
    let attachInner !e = do
            wd `shouldAlsoKeepAlive` e
            onEventWhile e $ trigger t
            -- because inners could be killed externally ...
            traverse_ (\w -> onCleanup (leash w) (writeIORef needsWashRef True) ) $ watchdogs e
            needsWash <- atomicModifyIORef' needsWashRef (False,)
            -- ... we need to gc the watchdog references
            when needsWash $ washWatchdog wd
            return True

    onEventWhile evev attachInner
    return ev_



-- | switch needs to run in IO: switch depends on the history of outer events that select the inner events, so we need to know when it was started.
switch :: Event (Event a) -> IO (Event a)
switch !event_of_events = do
    (!result_event,!t)<-newEvent
    result_event `shouldAlsoKeepAlive` event_of_events
    wd <- spawnWatchdog
    result_event `shouldAlsoKeepAlive` wd
    unregisterRef <- newIORef $ return ()

    (!tbs,!tbr)<-createTeleBox :: IO (TeleBoxSender a,TeleBoxReceiver a)

    let outer = Listener $ \ev -> do
                    b <- isAlive t
                    if b
                    then do
                        wd `protectsOnly` ev
                        !u' <- registerOnEvent ev tbs
                        unregister <- atomicModifyIORef unregisterRef (\u->(u',u))
                        unregister
                        return $ Just outer
                    else do
                        wd `protectsOnly` ()
                        let !u' = return ()
                        unregister <- atomicModifyIORef unregisterRef (\u->(u',u))
                        unregister
                        return Nothing
    unregOuter <- listenOnEvent event_of_events outer

    let inner = Listener $ \a -> do
                    b <- trigger t a
                    if b
                    then do
                        return $ Just inner
                    else do
                        unregOuter
                        return Nothing
    listenOnSendBox tbr Just inner

    return result_event


-- | same as `Watchdog.keepsAlive`
shouldAlsoKeepAlive :: (KeepAlive event_a, KeepAlive event_b) => event_a -> event_b -> IO ()
shouldAlsoKeepAlive = keepsAlive

------

