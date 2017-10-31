module Utils where

import qualified Data.Set as S

newtype Plain a = Plain a  -- ^ a plain, non-variational value
             deriving (Eq, Ord)

-- | smart constructor for plain values
plain :: a -> Plain a
plain = Plain

-- | affix a space to anything that can be shown
affixSp :: (Show a) => a -> String
affixSp = (++ " ") . show

-- | Given list of anything that can be shown, pretty format it
format :: (Show a) => [a] -> String
format [] = ""
format [x] = show x
format (x:xs) = mconcat $ hed : mid ++ [lst]
  where hed = affixSp x
        mid = fmap affixSp . init $ xs
        lst = show $ last xs

-- | smart constructor for comments
smtComment :: (Show a) => a -> String
smtComment stmt = mconcat [ "c "
                          , show stmt
                          , "\n"
                          ]

-- | smart constructor for Variables
smtVars :: (Integral a) => [a] -> S.Set Integer
smtVars = S.fromList . fmap toInteger

-- | Show typeclasse
instance Show a => Show (Plain a) where
  show (Plain a) = show a
