module Moskstraumen.DList (module Moskstraumen.DList) where

import Data.Function (on)
import Moskstraumen.Prelude hiding (toList)
import qualified Text.Read as Read

------------------------------------------------------------------------

newtype DList a = DList {unDList :: [a] -> [a]}

{-# INLINE empty #-}
empty :: DList a
empty = DList id

{-# INLINE singleton #-}
singleton :: a -> DList a
singleton x = DList (x :)

{-# INLINE append #-}
append :: DList a -> DList a -> DList a
append (DList xs) (DList ys) = DList (xs . ys)

{-# INLINE concat #-}
concat :: [DList a] -> DList a
concat = foldr append empty

{-# INLINE (<|) #-}
(<|) :: a -> DList a -> DList a
x <| xs = append (singleton x) xs

{-# INLINE (|>) #-}
(|>) :: DList a -> a -> DList a
xs |> x = append xs (singleton x)

{-# INLINE fromList #-}
fromList :: [a] -> DList a
fromList = DList . (++)

{-# INLINE toList #-}
toList :: DList a -> [a]
toList (DList xs) = xs []

instance Semigroup (DList a) where
  {-# INLINE (<>) #-}
  (<>) = append

instance Monoid (DList a) where
  {-# INLINE mempty #-}
  mempty = empty

instance (Eq a) => Eq (DList a) where
  (==) = (==) `on` toList

instance (Ord a) => Ord (DList a) where
  compare = compare `on` toList

instance (Read a) => Read (DList a) where
  readPrec = Read.parens $
    Read.prec 10 $ do
      Read.Ident "fromList" <- Read.lexP
      dl <- Read.readPrec
      return (fromList dl)
  readListPrec = Read.readListPrecDefault

instance (Show a) => Show (DList a) where
  showsPrec p dl =
    showParen (p > 10) $
      showString "fromList " . shows (toList dl)
