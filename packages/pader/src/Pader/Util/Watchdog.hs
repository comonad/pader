
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

-- |
-- A 'Watchdog' is like a tamagochi or pet to keep around. On a 'Leash'.
--
-- A 'Watchdog' is like a barking Cannary,
--
-- it 'isAlive' only as long it was neither /garbage collected/ nor explicitely 'kill'ed.
--
-- See 'keepAlive', 'keptAlive', 'keepsAlive' to prevent it from /garbage collection/.
--
-- A 'Watchdog' can prevent other 'Watchdog's from /garbage collection/,
--
-- which means that unlike a Cannary a 'Watchdog' also protects others.

module Pader.Util.Watchdog (
    -- * Basics for a pet
    Watchdog(),spawnWatchdog,leash,Leash(),kill,
    -- * @KeepAlive@
    keepAlive,keptAlive,keepsAlive,KeepAlive(..),
    -- * @IsAlive@
    IsAlive(..),onCleanup,washWatchdog,
    -- * A @Watchdog@ keeps its /pack/ alive
    -- $pack
    setProtectedPack,getProtectedPack,addProtectedPack,
    protectsOnly,protectsAlso
) where



import Control.Concurrent
import Control.Concurrent.MVar
import Control.Exception (evaluate,bracket,bracket_, finally)
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader

import Data.Foldable as Foldable
import Data.IORef
import Data.IntMap.Strict as IntMap
import Data.Maybe
import Data.Function (on)

import System.Mem.Weak
import Pader.Util.Bag as Bag
import System.Mem.StableName as StableName

-- | It comes with a 'Leash'.
data Watchdog = Watchdog_ !(IORef (Bag Watchdog)) !Leash
instance Eq Watchdog where (==) = (==) `on` leash

-- | Cute puppy.
spawnWatchdog :: IO Watchdog
spawnWatchdog = do
    !r <- newIORef mempty
    !fin <- newMVar $ Just(return ())
    !w <- mkWeakIORef r $! do modifyMVar_ fin (\cu -> sequence_ cu >> return Nothing)
    stable<-StableName.makeStableName r
    return $! Watchdog_ r (Leash_ w fin stable)

leash :: Watchdog -> Leash
leash (Watchdog_ r l) = l


-- | A 'Leash' allows you to test whether a distant 'Watchdog' 'isAlive'.
--
-- But you can't keep it alive through the 'Leash'.
--
-- (The implementation is based on a weak reference.)
data Leash = Leash_ !(Weak (IORef (Bag Watchdog))) !(MVar (Maybe(IO ()))) !(StableName (IORef (Bag Watchdog)))
instance Eq Leash where
    (Leash_ _ _ s1) == (Leash_ _ _ s2) = s1 == s2

-- | Yep, you can explicitely kill a 'Watchdog'. This is for explicit cleanup purposes.
--
-- It will stop protecting others, and its `onCleanup` routine will be executed.
kill :: Watchdog -> IO ()
kill wd = do
    wd `setProtectedPack` mempty -- do not protect pack anymore
    let (Leash_ w _ _) = leash wd
    System.Mem.Weak.finalize w


-- | You only need an indirect reference to the 'Watchdog' to prevent it from /garbage collection/.
--
-- But the compiler might optimize simple things away; so this is how to anchor it to a specific point in time within (or rather at the end of) a thread.
keepAlive :: KeepAlive a => a -> IO ()
keepAlive = traverse_ (\(Watchdog_ r l)->readIORef r) . watchdogs


-- | For those rare cases that we might have to remove references to dead watchdogs that we still protect
washWatchdog :: KeepAlive a => a -> IO ()
washWatchdog = traverse_ (\(Watchdog_ r l)->wash r) . watchdogs
    where
        wash :: IORef (Bag Watchdog) -> IO ()
        wash r = do
            pack <- readIORef r
            let packL = Bag.toList pack
            l_alive <- traverse isAlive packL
            let dead = [ d | (d,False) <- packL `zip` l_alive]
            unless (Foldable.null dead) $ do
                let f (d:ds) (x:xs) = if d==x then f ds xs else x:f (d:ds) xs
                    f _ x = x
                atomicModifyIORef' r $ \a -> (Bag.fromList $ f dead $ Bag.toList a, ())

-- | For convenience reasons, this puts the 'keepAlive' at the end (via 'finally').
--
-- Even better, instead of...
--
-- > forever $ keptAlive dog $ do something
--
-- you can be more efficient with:
--
-- > keptAlive dog (forever $ do something)
--
-- Keep in mind that the following cannot work:
--
-- > (forever $ do something) >> keepAlive dog
keptAlive :: (KeepAlive a) => a -> IO b -> IO b
keptAlive = flip finally . keepAlive

-- | This orders a 'Watchdog' to protect other @Watchdogs@ by adding them to its /pack/.
keepsAlive :: (KeepAlive guard, KeepAlive a) => guard -> a -> IO ()
keepsAlive guard a = (`protectsAlso` a) `traverse_` watchdogs guard

-- | Canonically, only 'Watchdog's can be kept alive. Not through 'Leash'es, though.
class KeepAlive x where
    watchdogs :: x -> Bag Watchdog

instance KeepAlive Watchdog where
    watchdogs = pure
instance KeepAlive () where
    watchdogs = const mempty
instance (KeepAlive a) => KeepAlive (Bag a) where
    watchdogs = (>>= watchdogs)
instance (KeepAlive a) => KeepAlive [a] where
    watchdogs = mconcat . fmap watchdogs
instance (KeepAlive a,KeepAlive b) => KeepAlive (a,b) where
    watchdogs (!a,!b) = watchdogs a <> watchdogs b
instance (KeepAlive a,KeepAlive b,KeepAlive c) => KeepAlive (a,b,c) where
    watchdogs (!a,!b,!c) = watchdogs a <> watchdogs b <> watchdogs c
instance (KeepAlive a,KeepAlive b,KeepAlive c,KeepAlive d) => KeepAlive (a,b,c,d) where
    watchdogs (!a,!b,!c,!d) = watchdogs a <> watchdogs b <> watchdogs c <> watchdogs d


-- | 'isAlive' of a 'Watchdog' is only true as long as it was neither 'kill'ed nor /garbage collected/.
--
--   'isAlive' of a 'Leash' is only true as long as the 'Watchdog' at the end of that @Leash@ 'isAlive'.
--
--   For convenience reasons, the class 'IsAlive' represents anything that defines its own 'isAlive' status on 'Watchdog's or 'Leash'es.
class IsAlive x where
    isAlive :: IsAlive x => x -> IO Bool

instance IsAlive Leash where
    isAlive (Leash_ w fin _) = isJust <$> deRefWeak w
instance IsAlive Watchdog where
    isAlive = isAlive . leash


-- | When a 'Watchdog' is 'kill'ed or /garbage collected/, this will be executed.
onCleanup :: Leash -> IO () -> IO ()
onCleanup (Leash_ w fin _) !cl = do
    modifyMVar_ fin $ \ !mf -> do
        maybe (cl >> return Nothing) (\f->return . Just $ f>>cl) mf



{- $pack
With this you mold the rules of /garbage collection/.
-}

setProtectedPack :: Watchdog -> Bag Watchdog -> IO ()
setProtectedPack (Watchdog_ r _) wds = mapM_ evaluate wds >> writeIORef r wds

getProtectedPack :: Watchdog -> IO (Bag Watchdog)
getProtectedPack (Watchdog_ r _) = readIORef r

-- | Any alive 'Watchdog' can protect (aka keep alive) a pack of other 'Watchdogs'. An Alpha so to speak.
addProtectedPack :: Watchdog -> (Bag Watchdog) -> IO ()
addProtectedPack (Watchdog_ r _) !pack = do
    x <- atomicModifyIORef r $! \ !a->let b=pack<>a in b `seq` (b,b)
    mapM_ evaluate x


protectsOnly :: KeepAlive x => Watchdog -> x -> IO ()
protectsOnly wd x = wd `setProtectedPack` watchdogs x
protectsAlso :: KeepAlive x => Watchdog -> x -> IO ()
protectsAlso wd x = wd `addProtectedPack` watchdogs x


