-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.TypeChecker.Monad
-- Copyright   :  (c) Phil Freeman 2013
-- License     :  MIT
--
-- Maintainer  :  Phil Freeman <paf31@cantab.net>
-- Stability   :  experimental
-- Portability :
--
-- |
-- Monads for type checking and type inference and associated data types
--
-----------------------------------------------------------------------------

{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleInstances, RankNTypes, DeriveDataTypeable,
    GADTs, StandaloneDeriving, MultiParamTypeClasses, FlexibleContexts #-}

module Language.PureScript.TypeChecker.Monad where

import Language.PureScript.Types
import Language.PureScript.Kinds
import Language.PureScript.Values
import Language.PureScript.Names
import Language.PureScript.Unknown
import Language.PureScript.Declarations

import Data.Data
import Data.Maybe
import Data.Monoid
import Data.Generics (mkT, everywhere)

import Control.Applicative
import Control.Monad.State
import Control.Monad.Error
import Control.Monad.Reader
import Control.Arrow ((***))

import qualified Data.Map as M

-- |
-- The type of a name in the @Environment@
--
data NameKind
  -- |
  -- A value introduced as a binding in a module
  --
  = Value
  -- |
  -- A foreign import
  --
  | Extern ForeignImportType
  -- |
  -- An alias for a value in another module, introduced using an import declaration
  --
  | Alias ModuleName Ident
  -- |
  -- A local name introduced using a lambda abstraction, variable introduction or binder
  --
  | LocalVariable
  -- |
  -- A data constructor
  --
  | DataConstructor deriving Show

-- |
-- The type of a type declaration
--
data TypeDeclarationKind
  -- |
  -- A data constructor
  --
  = Data
  -- |
  -- A data type foreign import
  --
  | ExternData
  -- |
  -- A type synonym
  --
  | TypeSynonym
  -- |
  -- An alias for a type in another module, introduced using an import declaration
  --
  | DataAlias ModuleName ProperName
  -- |
  -- A local type name introduced using a forall quantifier
  --
  | LocalTypeVariable deriving Show

-- |
-- The @Environment@ defines all values and types which are currently in scope:
--
data Environment = Environment {
  -- |
  -- Value names currently in scope
  --
    names :: M.Map (ModuleName, Ident) (Type, NameKind)
  -- |
  -- Type names currently in scope
  --
  , types :: M.Map (ModuleName, ProperName) (Kind, TypeDeclarationKind)
  -- |
  -- Data constructors currently in scope, along with their associated data type constructors
  --
  , dataConstructors :: M.Map (ModuleName, ProperName) (Type, NameKind)
  -- |
  -- Type synonyms currently in scope
  --
  , typeSynonyms :: M.Map (ModuleName, ProperName) ([String], Type)
  -- |
  -- Available type class dictionaries
  --
  , typeClassDictionaries :: [TypeClassDictionaryInScope]
  } deriving (Show)

-- |
-- An empty environment with no values and no types defined
--
emptyEnvironment :: Environment
emptyEnvironment = Environment M.empty M.empty M.empty M.empty []

-- |
-- Temporarily bind a collection of names to values
--
bindNames :: (MonadState CheckState m) => M.Map (ModuleName, Ident) (Type, NameKind) -> m a -> m a
bindNames newNames action = do
  orig <- get
  modify $ \st -> st { checkEnv = (checkEnv st) { names = newNames `M.union` (names . checkEnv $ st) } }
  a <- action
  modify $ \st -> st { checkEnv = (checkEnv st) { names = names . checkEnv $ orig } }
  return a

-- |
-- Temporarily bind a collection of names to types
--
bindTypes :: (MonadState CheckState m) => M.Map (ModuleName, ProperName) (Kind, TypeDeclarationKind) -> m a -> m a
bindTypes newNames action = do
  orig <- get
  modify $ \st -> st { checkEnv = (checkEnv st) { types = newNames `M.union` (types . checkEnv $ st) } }
  a <- action
  modify $ \st -> st { checkEnv = (checkEnv st) { types = types . checkEnv $ orig } }
  return a

-- |
-- Temporarily make a collection of type class dictionaries available
--
withTypeClassDictionaries :: (MonadState CheckState m) => [TypeClassDictionaryInScope] -> m a -> m a
withTypeClassDictionaries entries action = do
  orig <- get
  modify $ \st -> st { checkEnv = (checkEnv st) { typeClassDictionaries = entries ++ (typeClassDictionaries . checkEnv $ st) } }
  a <- action
  modify $ \st -> st { checkEnv = (checkEnv st) { typeClassDictionaries = typeClassDictionaries . checkEnv $ orig } }
  return a

-- |
-- Get the currently available list of type class dictionaries
--
getTypeClassDictionaries :: (Functor m, MonadState CheckState m) => m [TypeClassDictionaryInScope]
getTypeClassDictionaries = typeClassDictionaries . checkEnv <$> get

-- |
-- Temporarily bind a collection of names to local variables
--
bindLocalVariables :: (Functor m, MonadState CheckState m) => ModuleName -> [(Ident, Type)] -> m a -> m a
bindLocalVariables moduleName bindings action =
  bindNames (M.fromList $ flip map bindings $ \(name, ty) -> ((moduleName, name), (ty, LocalVariable))) action

-- |
-- Temporarily bind a collection of names to local type variables
--
bindLocalTypeVariables :: (Functor m, MonadState CheckState m) => ModuleName -> [(ProperName, Kind)] -> m a -> m a
bindLocalTypeVariables moduleName bindings action =
  bindTypes (M.fromList $ flip map bindings $ \(name, k) -> ((moduleName, name), (k, LocalTypeVariable))) action

-- |
-- Lookup the type of a value by name in the @Environment@
--
lookupVariable :: (Functor m, MonadState CheckState m, MonadError String m) => ModuleName -> Qualified Ident -> m Type
lookupVariable currentModule (Qualified moduleName var) = do
  env <- getEnv
  case M.lookup (fromMaybe currentModule moduleName, var) (names env) of
    Nothing -> throwError $ show var ++ " is undefined"
    Just (ty, _) -> return ty

-- |
-- Lookup the kind of a type by name in the @Environment@
--
lookupTypeVariable :: (Functor m, MonadState CheckState m, MonadError String m) => ModuleName -> Qualified ProperName -> m Kind
lookupTypeVariable currentModule (Qualified moduleName name) = do
  env <- getEnv
  case M.lookup (fromMaybe currentModule moduleName, name) (types env) of
    Nothing -> throwError $ "Type variable " ++ show name ++ " is undefined"
    Just (k, _) -> return k

-- |
-- Canonicalize an identifier by resolving any aliases introduced by module imports
--
canonicalize :: ModuleName -> Environment -> Qualified Ident -> (ModuleName, Ident)
canonicalize _ _ (Qualified (Just mn) i) = (mn, i)
canonicalize mn env (Qualified Nothing i) = case (mn, i) `M.lookup` names env of
  Just (_, Alias mn' i') -> (mn', i')
  _ -> (mn, i)

-- |
-- Canonicalize a type variable by resolving any aliases introduced by module imports
--
canonicalizeType :: ModuleName -> Environment -> Qualified ProperName -> (ModuleName, ProperName)
canonicalizeType _ _ (Qualified (Just mn) nm) = (mn, nm)
canonicalizeType mn env (Qualified Nothing nm) = case (mn, nm) `M.lookup` types env of
  Just (_, DataAlias mn' pn') -> (mn', pn')
  _ -> (mn, nm)

-- |
-- State required for type checking:
--
data CheckState = CheckState {
  -- |
  -- The current @Environment@
  --
    checkEnv :: Environment
  -- |
  -- The next fresh unification variable name
  --
  , checkNextVar :: Int
  -- |
  -- The next type class dictionary name
  --
  , checkNextDictName :: Int
  }

-- |
-- The type checking monad, which provides the state of the type checker, and error reporting capabilities
--
newtype Check a = Check { unCheck :: StateT CheckState (Either String) a }
  deriving (Functor, Monad, Applicative, MonadPlus, MonadState CheckState, MonadError String)

-- |
-- Get the current @Environment@
--
getEnv :: (Functor m, MonadState CheckState m) => m Environment
getEnv = checkEnv <$> get

-- |
-- Update the @Environment#
--
putEnv :: (MonadState CheckState m) => Environment -> m ()
putEnv env = modify (\s -> s { checkEnv = env })

-- |
-- Modify the @Environment@
--
modifyEnv :: (MonadState CheckState m) => (Environment -> Environment) -> m ()
modifyEnv f = modify (\s -> s { checkEnv = f (checkEnv s) })

-- |
-- Run a computation in the Check monad, failing with an error, or succeeding with a return value and the final @Environment@.
--
runCheck :: Check a -> Either String (a, Environment)
runCheck c = do
  (a, s) <- flip runStateT (CheckState emptyEnvironment 0 0) $ unCheck c
  return (a, checkEnv s)

-- |
-- Make an assertion, failing with an error message
--
guardWith :: (MonadError e m) => e -> Bool -> m ()
guardWith _ True = return ()
guardWith e False = throwError e

-- |
-- Rethrow an error with a more detailed error message in the case of failure
--
rethrow :: (MonadError e m) => (e -> e) -> m a -> m a
rethrow f = flip catchError $ \e -> throwError (f e)

-- |
-- Generate new type class dictionary name
--
freshDictionaryName :: Check Int
freshDictionaryName = do
  n <- checkNextDictName <$> get
  modify $ \s -> s { checkNextDictName = succ (checkNextDictName s) }
  return n

-- |
-- A substitution maintains a mapping from unification variables to their values, ensuring that
-- the type of a unification variable matches the type of its value.
--
newtype Substitution = Substitution { runSubstitution :: forall t. (Unifiable t) => Unknown t -> t }

instance Monoid Substitution where
  mempty = Substitution unknown
  s1 `mappend` s2 = Substitution $ \u -> apply s1 (apply s2 (unknown u))

-- |
-- State for the substitution monad, which contains the current substitution
--
data SubstState = SubstState { substSubst :: Substitution }

-- |
-- Configuration for the substitution monad, constaining the current module
--
newtype SubstContext = SubstContext { substCurrentModule :: ModuleName } deriving (Show)

-- |
-- The substitution monad, which provides the means to unify values to generate a substitution, in addition to
-- the actions supported by the type checking monad @Check@.
--
newtype Subst a = Subst { unSubst :: ReaderT SubstContext (StateT SubstState Check) a }
  deriving (Functor, Monad, Applicative, MonadPlus, MonadReader SubstContext)

instance MonadState CheckState Subst where
  get = Subst . lift . lift $ get
  put = Subst . lift . lift . put

deriving instance MonadError String Subst

-- |
-- Lift a computation in the @Check@ monad into the substitution monad.
--
liftCheck :: Check a -> Subst a
liftCheck = Subst . lift . lift

-- |
-- Get the current substitution monad state
--
getSubstState :: Subst SubstState
getSubstState = Subst . lift $ get

-- |
-- Run a computation in the substitution monad, generating a return value and the final substitution.
--
runSubst :: SubstContext -> Subst a -> Check (a, Substitution)
runSubst context subst = do
  (a, s) <- flip runStateT (SubstState mempty) . flip runReaderT context . unSubst $ subst
  return (a, substSubst s)

-- |
-- Generate a substitution from a substitution function for a single type
--
substituteWith :: (Typeable t) => (Unknown t -> t) -> Substitution
substituteWith f = Substitution $ \u -> fromMaybe (unknown u) $ do
  u1 <- cast u
  cast (f u1)

-- |
-- Substitute a single unification variable
--
substituteOne :: (Unifiable t) => Unknown t -> t -> Substitution
substituteOne u t = substituteWith $ \u1 ->
  case u1 of
    u2 | u2 == u -> t
       | otherwise -> unknown u2

-- |
-- Replace a unification variable with the specified value in the current substitution
--
replace :: (Unifiable t) => Unknown t -> t -> Subst ()
replace u t' = do
  sub <- substSubst <$> Subst get
  let t = apply sub t'
  occursCheck u t
  let current = apply sub $ unknown u
  case isUnknown current of
    Just u1 | u1 == u -> return ()
    _ -> current ~~ t
  Subst . modify $ \s -> s { substSubst = substituteOne u t <> substSubst s }

-- |
-- Identifies types which support unification
--
class (Typeable t, Data t, Show t) => Unifiable t where
  unknown :: Unknown t -> t
  (~~) :: t -> t -> Subst ()
  isUnknown :: t -> Maybe (Unknown t)
  apply :: Substitution -> t -> t
  unknowns :: t -> [Int]

instance (Unifiable a) => Unifiable [a] where
  unknown _ = error "not supported"
  (~~) = zipWithM_ (~~)
  isUnknown _ = error "not supported"
  apply s = map (apply s)
  unknowns = concatMap unknowns

-- |
-- Perform the occurs check, to make sure a unification variable does not occur inside a value
--
occursCheck :: (Unifiable t) => Unknown s -> t -> Subst ()
occursCheck (Unknown u) t =
  case isUnknown t of
    Nothing -> guardWith "Occurs check fails" (u `notElem` unknowns t)
    _ -> return ()

-- |
-- Generate a fresh untyped unification variable
--
fresh' :: Subst Int
fresh' = do
  n <- checkNextVar <$> get
  modify $ \s -> s { checkNextVar = succ (checkNextVar s) }
  return n

-- |
-- Generate a fresh unification variable at a specific type
--
fresh :: (Unifiable t) => Subst t
fresh = unknown . Unknown <$> fresh'

-- |
-- Replace any unqualified names in a type wit their qualified versionss
--
qualifyAllUnqualifiedNames :: (Data d) => ModuleName -> Environment -> d -> d
qualifyAllUnqualifiedNames mn env = everywhere (mkT go)
  where
  go :: Type -> Type
  go (TypeConstructor nm) = TypeConstructor $ qualify' nm
  go (SaturatedTypeSynonym nm args) = SaturatedTypeSynonym (qualify' nm) args
  go (ConstrainedType constraints ty) = ConstrainedType (map (qualify' *** id) constraints) ty
  go other = other
  qualify' qual = let (mn', pn') = canonicalizeType mn env qual
                  in Qualified (Just mn') pn'
