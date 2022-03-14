
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
-- See 'keepAlive', 'keptAlive', 'keepsAlive', etc.. to prevent it from /garbage collection/.
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
    IsAlive(..),onCleanup,
    -- * A @Watchdog@ keeps its /pack/ alive
    -- $pack
    setProtectedPack,getProtectedPack,addProtectedPack,
    module StateVar,
    protectsOnly,protectsAlso,
    alsoKeepsAlive
) where



import Control.Concurrent
import Control.Concurrent.MVar
import Control.Exception (evaluate,bracket,bracket_, finally)
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader

import Data.Foldable
import Data.IORef
import Data.IntMap.Strict as IntMap
import Data.Maybe
import Data.StateVar as StateVar

import System.Mem.Weak
import Pader.Util.Bag as Bag

-- | It comes with a 'Leash'.
data Watchdog = Watchdog_ !(IORef (Bag Watchdog)) !Leash

-- | Cute puppy.
spawnWatchdog :: IO Watchdog
spawnWatchdog = do
    !r <- newIORef mempty
    !fin <- newMVar $ Just(return ())
    !w <- mkWeakIORef r $! do modifyMVar_ fin (\ !cu -> maybe (return ()) id cu >> return Nothing)
    return $! Watchdog_ r (Leash_ w fin)

leash :: Watchdog -> Leash
leash (Watchdog_ r l) = l


-- | A 'Leash' allows you to test whether a distant 'Watchdog' 'isAlive'.
--
-- But you can't keep it alive through the 'Leash'.
--
-- (The implementation is based on a weak reference.)
data Leash = Leash_ !(Weak (IORef (Bag Watchdog))) !(MVar (Maybe(IO ())))


-- | Yep, you can explicitely kill a 'Watchdog'. Even more morbid than that:
--
-- Technically, it will be killed via its 'Leash' (by finalizing its 'Weak' pointer), but that is not the purpose of this library.
--
-- So, you need direct access to the 'Watchdog'. This is for explicit cleanup purposes.
kill :: Watchdog -> IO ()
kill wd = do
    wd $= mempty -- do not protect pack anymore
    let (Leash_ w _) = leash wd
    System.Mem.Weak.finalize w


-- | You only need an indirect reference to the 'Watchdog' to prevent it from /garbage collection/.
--
-- But the compiler might optimize simple things away; so this is how to anchor it to a specific point in time within (or rather at the end of) a thread.
keepAlive :: KeepAlive a => a -> IO ()
keepAlive = traverse_ (\(Watchdog_ r l)->readIORef r) . watchdogs

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

-- | Internally, this orders a 'Watchdog' to protect other @Watchdogs@ by adding them to its /pack/.
keepsAlive :: (KeepAlive guard,KeepAlive a) => guard -> a -> IO ()
keepsAlive guard a = watchdogs guard `forM_` ($~ (watchdogs a<>))

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
    isAlive (Leash_ w fin) = isJust <$> deRefWeak w
instance IsAlive Watchdog where
    isAlive = isAlive . leash


-- | When a 'Watchdog' is 'kill'ed or /garbage collected/, this will be executed.
onCleanup :: Leash -> IO () -> IO ()
onCleanup (Leash_ w fin) !cl = do
    modifyMVar_ fin $ \ !mf -> do
        maybe (cl >> return Nothing) (\f->return . Just $ f>>cl) mf



{- $pack
With this you mold the rules of /garbage collection/.
-}

-- Same as '$=', see 'HasSetter'.
setProtectedPack :: Watchdog -> Bag Watchdog -> IO ()
setProtectedPack (Watchdog_ r _) wds = mapM_ evaluate wds >> writeIORef r wds

-- Same as 'get', see 'HasGetter'.
getProtectedPack :: Watchdog -> IO (Bag Watchdog)
getProtectedPack (Watchdog_ r _) = readIORef r

-- Any alive 'Watchdog' can protect (aka keep alive) a pack of other 'Watchdogs'. An Alpha so to speak.
addProtectedPack :: Watchdog -> (Bag Watchdog) -> IO ()
addProtectedPack wd !pack = wd $~ (pack<>)

instance HasGetter Watchdog (Bag Watchdog) where
    get = liftIO . getProtectedPack
instance HasSetter Watchdog (Bag Watchdog) where
    ($=) wd = liftIO . setProtectedPack wd
instance HasUpdate Watchdog (Bag Watchdog) (Bag Watchdog) where
    ($~) (Watchdog_ r _) !f = liftIO $ do
        x <- atomicModifyIORef r $! \ !a->let b=f a in b `seq` (b,b)
        mapM_ evaluate x
    ($~!) = ($~)



protectsOnly :: KeepAlive x => Watchdog -> x -> IO ()
protectsOnly wd x = wd `setProtectedPack` watchdogs x
protectsAlso :: KeepAlive x => Watchdog -> x -> IO ()
protectsAlso wd x = wd `addProtectedPack` watchdogs x

alsoKeepsAlive :: (KeepAlive a, KeepAlive b) => a -> b -> IO ()
alsoKeepsAlive a b = traverse_ (\w->protectsAlso w b) $ watchdogs a


