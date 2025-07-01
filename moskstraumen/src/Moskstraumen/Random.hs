module Moskstraumen.Random (module Moskstraumen.Random) where

import qualified System.Random as Random
import qualified Prelude

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

exponential :: Double -> Prng -> (Double, Prng)
exponential mean prng =
  let
    (u, prng') = randomR (0, 1) prng
  in
    ((-mean) * Prelude.log u, prng')

poisson :: Double -> Prng -> (Int, Prng)
poisson lambda = go 1.0 0
  where
    a :: Double
    a = exp (-lambda)

    go :: Double -> Int -> Prng -> (Int, Prng)
    go b i prng =
      let (u, prng') = randomR (0.0, 1.0) prng
          b' = b * u
      in  if b' < a then (i, prng') else go b' (i + 1) prng'
