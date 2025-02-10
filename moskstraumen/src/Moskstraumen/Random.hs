module Moskstraumen.Random (module Moskstraumen.Random) where

import qualified System.Random as Random

import Moskstraumen.Prelude

------------------------------------------------------------------------

newtype Prng = Prng Random.StdGen

type Seed = Int

------------------------------------------------------------------------

newPrng :: Maybe Seed -> IO (Prng, Seed)
newPrng Nothing = do
  seed <- Random.randomIO
  return (Prng (Random.mkStdGen seed), seed)
newPrng (Just seed) = return (Prng (Random.mkStdGen seed), seed)

mkPrng :: Int -> Prng
mkPrng seed = Prng (Random.mkStdGen seed)

splitPrng :: Prng -> (Prng, Prng)
splitPrng (Prng stdGen) =
  let (stdGen', stdGen'') = Random.split stdGen
  in  (Prng stdGen', Prng stdGen'')

randomR :: (Random.Random a) => (a, a) -> Prng -> (a, Prng)
randomR (lo, hi) (Prng stdGen) = Prng <$> Random.randomR (lo, hi) stdGen
