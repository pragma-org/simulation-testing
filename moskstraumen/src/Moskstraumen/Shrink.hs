module Moskstraumen.Shrink (module Moskstraumen.Shrink) where

import Data.Containers.ListUtils (nubOrd)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty

import Moskstraumen.Prelude

------------------------------------------------------------------------

-- | Shrink an integral number.
shrinkIntegral :: (Integral a) => a -> [a]
shrinkIntegral x =
  nubOrd
    $ [ -x
      | x < 0
      , -x > x
      ]
    ++ [ x'
       | x' <-
          takeWhile (<< x) (0 : [x - i | i <- drop 1 (iterate (`quot` 2) x)])
       ]
  where
    -- a << b is "morally" abs a < abs b, but taking care of overflow.
    a << b = case (a >= 0, b >= 0) of
      (True, True) -> a < b
      (False, False) -> a > b
      (True, False) -> a + b < 0
      (False, True) -> a + b > 0

-- | Shrink a list of values given a shrinking function for individual values.
shrinkList :: (a -> [a]) -> [a] -> [[a]]
shrinkList shr xs0 =
  concat
    [removes k n0 xs0 | k <- takeWhile (> 0) (iterate (`div` 2) n0)]
    ++ shrinkOne xs0
  where
    n0 = length xs0

    shrinkOne [] = []
    shrinkOne (x : xs) =
      [x' : xs | x' <- shr x]
        ++ [x : xs' | xs' <- shrinkOne xs]

    removes k n xs
      | k > n = []
      | null xs2 = [[]]
      | otherwise = xs2 : map (xs1 ++) (removes k (n - k) xs2)
      where
        xs1 = take k xs
        xs2 = drop k xs

------------------------------------------------------------------------

data Tree a = Node {root :: a, subtrees :: [Tree a]}
  deriving (Show)

instance Functor Tree where
  fmap f (Node x xs) = Node (f x) (map (fmap f) xs)

singleton :: a -> Tree a
singleton x = Node x []

unfoldTree :: forall a. (a -> [a]) -> a -> Tree a
unfoldTree f = go
  where
    go :: a -> Tree a
    go x = Node x (map go (f x))

------------------------------------------------------------------------

shrink ::
  forall m a b.
  (Monad m) =>
  (a -> m (Maybe b))
  -> (a -> [a])
  -> a
  -> m (NonEmpty (a, b))
shrink p shr x0 = go (unfoldTree shr x0)
  where
    go :: Tree a -> m (NonEmpty (a, b))
    go (Node x xs) = do
      xys' <- mapMaybeM' (p . root) xs
      case xys' of
        [] -> do
          my <- p x
          case my of
            Nothing -> undefined
            Just y -> return (NonEmpty.singleton (x, y))
        ((x', y') : _) ->
          NonEmpty.cons <$> pure (x, y') <*> go x'

mapMaybeM' :: (Monad m) => (a -> m (Maybe b)) -> [a] -> m [(a, b)]
mapMaybeM' op = foldr f (pure [])
  where
    f x ih = do
      my <- op x
      case my of
        Nothing -> ih
        Just y -> do
          xys <- ih
          return ((x, y) : xys)
{-# INLINE mapMaybeM' #-}
