{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable #-}

module Pader.Util.Bag (
    Bag(), fromList, toList, pure, mempty, (<>)
) where

import Data.Foldable
import GHC.Base (stimes)

-- | A Bag is a simple container like a free monoid, strict in its values.
--
--   Unlike a Cons list, mappend is O(1).
--
--   It's constructors join the design of
--
--    * a strict Maybe
--
--    * a strict List
--
--    * strict mappend
data Bag a = SFMempty
           | SFMsingleton !a
           | SFMcons !a !(Bag a)
           | SFMappend !(Bag a) !(Bag a)
    deriving (Functor,Foldable,Traversable)

instance Semigroup (Bag a) where
    SFMempty <> a = a
    a <> SFMempty = a
    SFMsingleton a <> b = SFMcons a b
    (<>) a b = SFMappend a b

instance Monoid (Bag a) where
    mempty = SFMempty


{-# RULES
  "Bag/fromList"  forall xs. toList (fromList xs) = xs
  #-}
{-# INLINE [3] fromList #-}
fromList :: [a] -> Bag a
fromList = foldl' (flip SFMcons) SFMempty . reverse

instance Applicative Bag where
    pure = SFMsingleton
    (<*>) fab fa = fromList $ toList fab <*> toList fa
    (*>) fa fb = stimes (length fa) fb
    (<*) fa fb = fa >>= (fromList . replicate (length fb))

instance Monad Bag where
    (>>=) ma a_mb = fromList $ toList ma >>= (toList . a_mb)
    (>>) = (*>)

