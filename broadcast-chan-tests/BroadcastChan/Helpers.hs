{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
module BroadcastChan.Helpers where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>),(<*>))
#endif

type family ParamFun (l :: [*]) r
type instance ParamFun '[] r = String -> r
type instance ParamFun (h ': t) r = h -> ParamFun t r

data Params :: [*] -> * where
    None :: Params '[]
    Param :: Show a => String -> (a -> b) -> [a] -> Params l -> Params (b ': l)

buildTree
    :: forall a l
     . (String -> [a] -> a)
    -> String
    -> ParamFun l a
    -> Params l
    -> a
buildTree labelFun label fun params = go params fun label
  where
    labelList :: [a] -> String -> a
    labelList = flip labelFun

    go :: Params k -> ParamFun k a -> String -> a
    go None result = result
    go (Param name derive values remainder) f =
        labelList . map buildBranch $ values
      where
        nextName v = show v ++ " " ++ name
        buildBranch = go remainder <$> f . derive <*> nextName
