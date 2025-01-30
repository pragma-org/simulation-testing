module Moskstraumen.Random (module Moskstraumen.Random) where

import System.Random

import Moskstraumen.Prelude

------------------------------------------------------------------------

newtype Prng = Prng StdGen

------------------------------------------------------------------------

newPrng :: Maybe Int -> IO (Prng, Int)
newPrng Nothing = do
  seed <- randomIO
  return (Prng (mkStdGen seed), seed)
newPrng (Just seed) = return (Prng (mkStdGen seed), seed)

mkPrng :: Int -> Prng
mkPrng seed = Prng (mkStdGen seed)
