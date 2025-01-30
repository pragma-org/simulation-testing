module Moskstraumen.Generate (module Moskstraumen.Generate) where

import Data.Maybe

import Moskstraumen.Prelude
import Moskstraumen.Random

------------------------------------------------------------------------

type Size = Int

newtype Gen a = Gen (Prng -> Size -> (a, Prng))

instance Monad Gen where
  return = pure
  Gen f >>= k = Gen $ \prng size ->
    let (x, prng') = f prng size
        Gen g = k x
    in  g prng' size

instance Applicative Gen where
  pure x = Gen (\prng _size -> (x, prng))
  (<*>) = ap

instance Functor Gen where
  fmap = liftM

runGen :: Gen a -> Prng -> Size -> (Prng, a)
runGen (Gen k) prng size = (prng', x)
  where
    (x, prng') = k prng size

------------------------------------------------------------------------

word8 :: Gen Word8
word8 = arbitrarySizedIntegral

int :: Gen Int
int = arbitrarySizedIntegral

------------------------------------------------------------------------

sized :: (Int -> Gen a) -> Gen a
sized k = Gen (\prng size -> let Gen f = k size in f prng size)

getSize :: Gen Size
getSize = sized pure

resize :: Size -> Gen a -> Gen a
resize size _ | size < 0 = error "resize: negative size"
resize size (Gen f) = Gen (\prng _size -> f prng size)

-- NOTE: This can be optimised later (if needed), see QuickCheck.
chooseInt :: (Int, Int) -> Gen Int
chooseInt (lo, hi) = Gen (\prng _size -> randomR (lo, hi) prng)

elements :: [a] -> Gen a
elements [] = error "elements used with empty list"
elements xs = (xs !!) `fmap` chooseInt (0, length xs - 1)

oneof :: [Gen a] -> Gen a
oneof [] = error "oneof used with empty list"
oneof gs = chooseInt (0, length gs - 1) >>= (gs !!)

vectorOf :: Int -> Gen a -> Gen [a]
vectorOf = replicateM

listOf :: Gen a -> Gen [a]
listOf gen = sized $ \n -> do
  k <- chooseInt (0, n)
  vectorOf k gen

chooseFloat :: Gen Float
chooseFloat = Gen (\prng _size -> randomR (0, 1) prng)

chooseDouble :: Gen Double
chooseDouble = Gen (\prng _size -> randomR (0, 1) prng)

generate' :: Gen a -> IO a
generate' (Gen g) = do
  (prng, _seed) <- newPrng Nothing
  let size = 30
  return (fst (g prng size))

sample' :: Gen a -> IO [a]
sample' g =
  generate' (sequence [resize n g | n <- [0, 2 .. 20]])

------------------------------------------------------------------------

suchThat :: Gen a -> (a -> Bool) -> Gen a
gen `suchThat` p = do
  mx <- gen `suchThatMaybe` p
  case mx of
    Just x -> return x
    Nothing -> sized (\n -> resize (n + 1) (gen `suchThat` p))

suchThatMap :: Gen a -> (a -> Maybe b) -> Gen b
gen `suchThatMap` f =
  fmap fromJust $ fmap f gen `suchThat` isJust

suchThatMaybe :: Gen a -> (a -> Bool) -> Gen (Maybe a)
gen `suchThatMaybe` p = sized (\n -> try n (2 * n))
  where
    try m n
      | m > n = return Nothing
      | otherwise = do
          x <- resize m gen
          if p x then return (Just x) else try (m + 1) n

------------------------------------------------------------------------

arbitrarySizedIntegral :: (Integral a) => Gen a
arbitrarySizedIntegral
  | isNonNegativeType fromI = arbitrarySizedNatural
  | otherwise = sized $ \n -> inBounds fromI (chooseInt (-n, n))
  where
    -- NOTE: this is a trick to make sure we get around lack of scoped type
    -- variables by pinning the result-type of fromIntegral.
    fromI = fromIntegral

isNonNegativeType :: (Enum a) => (Int -> a) -> Bool
isNonNegativeType fromI =
  case enumFromThen (fromI 1) (fromI 0) of
    [_, _] -> True
    _ -> False

arbitrarySizedNatural :: (Integral a) => Gen a
arbitrarySizedNatural =
  sized $ \n ->
    inBounds fromIntegral (chooseInt (0, n))

inBounds :: (Integral a) => (Int -> a) -> Gen Int -> Gen a
inBounds fi g = fmap fi (g `suchThat` (\x -> toInteger x == toInteger (fi x)))
