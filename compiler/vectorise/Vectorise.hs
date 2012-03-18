-- Main entry point to the vectoriser.  It is invoked iff the option '-fvectorise' is passed.
--
-- This module provides the function 'vectorise', which vectorises an entire (desugared) module.
-- It vectorises all type declarations and value bindings.  It also processes all VECTORISE pragmas
-- (aka vectorisation declarations), which can lead to the vectorisation of imported data types
-- and the enrichment of imported functions with vectorised versions.

module Vectorise ( vectorise )
where

import Vectorise.Type.Env
import Vectorise.Type.Type
import Vectorise.Convert
import Vectorise.Utils.Hoisting
import Vectorise.Exp
import Vectorise.Vect
import Vectorise.Env
import Vectorise.Monad

import HscTypes hiding      ( MonadThings(..) )
import CoreUnfold           ( mkInlineUnfolding )
import CoreFVs
import PprCore
import CoreSyn
import CoreMonad            ( CoreM, getHscEnv )
import Type
import Id
import DynFlags
import BasicTypes           ( isStrongLoopBreaker )
import Outputable
import Util                 ( zipLazy )
import MonadUtils

import Control.Monad
import Data.Maybe


-- |Vectorise a single module.
--
vectorise :: ModGuts -> CoreM ModGuts
vectorise guts
 = do { hsc_env <- getHscEnv
      ; liftIO $ vectoriseIO hsc_env guts
      }

-- Vectorise a single monad, given the dynamic compiler flags and HscEnv.
--
vectoriseIO :: HscEnv -> ModGuts -> IO ModGuts
vectoriseIO hsc_env guts
 = do {   -- Get information about currently loaded external packages.
      ; eps <- hscEPS hsc_env

          -- Combine vectorisation info from the current module, and external ones.
      ; let info = hptVectInfo hsc_env `plusVectInfo` eps_vect_info eps

          -- Run the main VM computation.
      ; Just (info', guts') <- initV hsc_env guts info (vectModule guts)
      ; return (guts' { mg_vect_info = info' })
      }

-- Vectorise a single module, in the VM monad.
--
vectModule :: ModGuts -> VM ModGuts
vectModule guts@(ModGuts { mg_tcs        = tycons
                         , mg_binds      = binds
                         , mg_fam_insts  = fam_insts
                         , mg_vect_decls = vect_decls
                         })
 = do { dumpOptVt Opt_D_dump_vt_trace "Before vectorisation" $ 
          pprCoreBindings binds
 
          -- Pick out all 'VECTORISE type' and 'VECTORISE class' pragmas
      ; let ty_vect_decls  = [vd | vd@(VectType _ _ _) <- vect_decls]
            cls_vect_decls = [vd | vd@(VectClass _)    <- vect_decls]
      
          -- Vectorise the type environment.  This will add vectorised
          -- type constructors, their representaions, and the
          -- conrresponding data constructors.  Moreover, we produce
          -- bindings for dfuns and family instances of the classes
          -- and type families used in the DPH library to represent
          -- array types.
      ; (new_tycons, new_fam_insts, tc_binds) <- vectTypeEnv tycons ty_vect_decls cls_vect_decls

          -- Family instance environment for /all/ home-package modules including those instances
          -- generated by 'vectTypeEnv'.
      ; (_, fam_inst_env) <- readGEnv global_fam_inst_env

          -- Vectorise all the top level bindings and VECTORISE declarations on imported identifiers
          -- NB: Need to vectorise the imported bindings first (local bindings may depend on them).
      ; let impBinds = [imp_id | Vect     imp_id _ <- vect_decls, isGlobalId imp_id] ++
                       [imp_id | VectInst imp_id   <- vect_decls, isGlobalId imp_id]
      ; binds_imp <- mapM vectImpBind impBinds
      ; binds_top <- mapM vectTopBind binds

      ; return $ guts { mg_tcs          = tycons ++ new_tycons
                        -- we produce no new classes or instances, only new class type constructors
                        -- and dfuns
                      , mg_binds        = Rec tc_binds : (binds_top ++ binds_imp)
                      , mg_fam_inst_env = fam_inst_env
                      , mg_fam_insts    = fam_insts ++ new_fam_insts
                      }
      }

-- Try to vectorise a top-level binding.  If it doesn't vectorise then return it unharmed.
--
-- For example, for the binding 
--
-- @  
--    foo :: Int -> Int
--    foo = \x -> x + x
-- @
--
-- we get
-- @
--    foo  :: Int -> Int
--    foo  = \x -> vfoo $: x                  
--
--    v_foo :: Closure void vfoo lfoo
--    v_foo = closure vfoo lfoo void        
--
--    vfoo :: Void -> Int -> Int
--    vfoo = ...
--
--    lfoo :: PData Void -> PData Int -> PData Int
--    lfoo = ...
-- @ 
--
-- @vfoo@ is the "vectorised", or scalar, version that does the same as the original
-- function foo, but takes an explicit environment.
--
-- @lfoo@ is the "lifted" version that works on arrays.
--
-- @v_foo@ combines both of these into a `Closure` that also contains the
-- environment.
--
-- The original binding @foo@ is rewritten to call the vectorised version
-- present in the closure.
--
-- Vectorisation may be surpressed by annotating a binding with a 'NOVECTORISE' pragma.  If this
-- pragma is used in a group of mutually recursive bindings, either all or no binding must have
-- the pragma.  If only some bindings are annotated, a fatal error is being raised.
-- FIXME: Once we support partial vectorisation, we may be able to vectorise parts of a group, or
--   we may emit a warning and refrain from vectorising the entire group.
--
vectTopBind :: CoreBind -> VM CoreBind
vectTopBind b@(NonRec var expr)
  = unlessNoVectDecl $
      do {   -- Vectorise the right-hand side, create an appropriate top-level binding and add it
             -- to the vectorisation map.
         ; (inline, isScalar, expr') <- vectTopRhs [] var expr
         ; var' <- vectTopBinder var inline expr'
         ; when isScalar $ 
             addGlobalScalarVar var
 
             -- We replace the original top-level binding by a value projected from the vectorised
             -- closure and add any newly created hoisted top-level bindings.
         ; cexpr <- tryConvert var var' expr
         ; hs <- takeHoisted
         ; return . Rec $ (var, cexpr) : (var', expr') : hs
         }
     `orElseErrV`
     do { emitVt "  Could NOT vectorise top-level binding" $ ppr var
        ; return b
        }
  where
    unlessNoVectDecl vectorise
      = do { hasNoVectDecl <- noVectDecl var
           ; when hasNoVectDecl $
               traceVt "NOVECTORISE" $ ppr var
           ; if hasNoVectDecl then return b else vectorise
           }
vectTopBind b@(Rec bs)
  = unlessSomeNoVectDecl $
      do { (vars', _, exprs', hs) <- fixV $ 
             \ ~(_, inlines, rhss, _) ->
               do {   -- Vectorise the right-hand sides, create an appropriate top-level bindings
                      -- and add them to the vectorisation map.
                  ; vars' <- sequence [vectTopBinder var inline rhs
                                      | (var, ~(inline, rhs)) <- zipLazy vars (zip inlines rhss)]
                  ; (inlines, areScalars, exprs') <- mapAndUnzip3M (uncurry $ vectTopRhs vars) bs
                  ; hs <- takeHoisted
                  ; if and areScalars
                    then      -- (1) Entire recursive group is scalar
                              --      => add all variables to the global set of scalars
                         do { mapM_ addGlobalScalarVar vars
                            ; return (vars', inlines, exprs', hs)
                            }
                    else      -- (2) At least one binding is not scalar
                              --     => vectorise again with empty set of local scalars
                         do { (inlines, _, exprs') <- mapAndUnzip3M (uncurry $ vectTopRhs []) bs
                            ; hs <- takeHoisted
                            ; return (vars', inlines, exprs', hs)
                            }
                  }
                       
             -- Replace the original top-level bindings by a values projected from the vectorised
             -- closures and add any newly created hoisted top-level bindings to the group.
         ; cexprs <- sequence $ zipWith3 tryConvert vars vars' exprs
         ; return . Rec $ zip vars cexprs ++ zip vars' exprs' ++ hs
         }
     `orElseErrV`
       return b    
  where
    (vars, exprs) = unzip bs

    unlessSomeNoVectDecl vectorise
      = do { hasNoVectDecls <- mapM noVectDecl vars
           ; when (and hasNoVectDecls) $
               traceVt "NOVECTORISE" $ ppr vars
           ; if and hasNoVectDecls 
             then return b                              -- all bindings have 'NOVECTORISE'
             else if or hasNoVectDecls 
             then cantVectorise noVectoriseErr (ppr b)  -- some (but not all) have 'NOVECTORISE'
             else vectorise                             -- no binding has a 'NOVECTORISE' decl
           }
    noVectoriseErr = "NOVECTORISE must be used on all or no bindings of a recursive group"

-- Add a vectorised binding to an imported top-level variable that has a VECTORISE [SCALAR] pragma
-- in this module.
--
-- RESTIRCTION: Currently, we cannot use the pragma vor mutually recursive definitions.
--
vectImpBind :: Id -> VM CoreBind
vectImpBind var
  = do {   -- Vectorise the right-hand side, create an appropriate top-level binding and add it
           -- to the vectorisation map.  For the non-lifted version, we refer to the original
           -- definition — i.e., 'Var var'.
           -- NB: To support recursive definitions, we tie a lazy knot.
       ; (var', _, expr') <- fixV $
           \ ~(_, inline, rhs) ->
             do { var' <- vectTopBinder var inline rhs
                ; (inline, isScalar, expr') <- vectTopRhs [] var (Var var)

                ; when isScalar $ 
                    addGlobalScalarVar var
                ; return (var', inline, expr')
                }

           -- We add any newly created hoisted top-level bindings.
       ; hs <- takeHoisted
       ; return . Rec $ (var', expr') : hs
       }

-- | Make the vectorised version of this top level binder, and add the mapping
--   between it and the original to the state. For some binder @foo@ the vectorised
--   version is @$v_foo@
--
--   NOTE: 'vectTopBinder' *MUST* be lazy in inline and expr because of how it is
--   used inside of 'fixV' in 'vectTopBind'.
--
vectTopBinder :: Var      -- ^ Name of the binding.
              -> Inline   -- ^ Whether it should be inlined, used to annotate it.
              -> CoreExpr -- ^ RHS of binding, used to set the 'Unfolding' of the returned 'Var'.
              -> VM Var   -- ^ Name of the vectorised binding.
vectTopBinder var inline expr
 = do {   -- Vectorise the type attached to the var.
      ; vty  <- vectType (idType var)
      
          -- If there is a vectorisation declartion for this binding, make sure that its type
          -- matches
      ; vectDecl <- lookupVectDecl var
      ; case vectDecl of
          Nothing             -> return ()
          Just (vdty, _) 
            | eqType vty vdty -> return ()
            | otherwise       -> 
              cantVectorise ("Type mismatch in vectorisation pragma for " ++ show var) $
                (text "Expected type" <+> ppr vty)
                $$
                (text "Inferred type" <+> ppr vdty)

          -- Make the vectorised version of binding's name, and set the unfolding used for inlining
      ; var' <- liftM (`setIdUnfoldingLazily` unfolding) 
                $  mkVectId var vty

          -- Add the mapping between the plain and vectorised name to the state.
      ; defGlobalVar var var'

      ; return var'
    }
  where
    unfolding = case inline of
                  Inline arity -> mkInlineUnfolding (Just arity) expr
                  DontInline   -> noUnfolding
{-
!!!TODO: dfuns and unfoldings:
           -- Do not inline the dfun; instead give it a magic DFunFunfolding
           -- See Note [ClassOp/DFun selection]
           -- See also note [Single-method classes]
        dfun_id_w_fun
           | isNewTyCon class_tc
           = dfun_id `setInlinePragma` alwaysInlinePragma { inl_sat = Just 0 }
           | otherwise
           = dfun_id `setIdUnfolding`  mkDFunUnfolding dfun_ty dfun_args
                     `setInlinePragma` dfunInlinePragma
 -}

-- | Vectorise the RHS of a top-level binding, in an empty local environment.
--
-- We need to distinguish four cases:
--
-- (1) We have a (non-scalar) vectorisation declaration for the variable (which explicitly provides
--     vectorised code implemented by the user)
--     => no automatic vectorisation & instead use the user-supplied code
-- 
-- (2) We have a scalar vectorisation declaration for a variable that is no dfun
--     => generate vectorised code that uses a scalar 'map'/'zipWith' to lift the computation
-- 
-- (3) We have a scalar vectorisation declaration for a variable that *is* a dfun
--     => generate vectorised code according to the the "Note [Scalar dfuns]" below
-- 
-- (4) There is no vectorisation declaration for the variable
--     => perform automatic vectorisation of the RHS (the definition may or may not be a dfun;
--        vectorisation proceeds differently depending on which it is)
--
-- Note [Scalar dfuns]
-- ~~~~~~~~~~~~~~~~~~~
--
-- Here is the translation scheme for scalar dfuns — assume the instance declaration:
--
--   instance Num Int where
--     (+) = primAdd
--   {-# VECTORISE SCALAR instance Num Int #-}
--
-- It desugars to
--
--   $dNumInt :: Num Int
--   $dNumInt = D:Num primAdd
--
-- We vectorise it to
--
--   $v$dNumInt :: V:Num Int
--   $v$dNumInt = D:V:Num (closure2 ((+) $dNumInt) (scalar_zipWith ((+) $dNumInt))))
--
-- while adding the following entry to the vectorisation map: '$dNumInt' --> '$v$dNumInt'.
--
-- See "Note [Vectorising classes]" in 'Vectorise.Type.Env' for the definition of 'V:Num'.
--
-- NB: The outlined vectorisation scheme does not require the right-hand side of the original dfun.
--     In fact, we definitely want to refer to the dfn variable instead of the right-hand side to 
--     ensure that the dictionary selection rules fire.
--
vectTopRhs :: [Var]           -- ^ Names of all functions in the rec block
           -> Var             -- ^ Name of the binding.
           -> CoreExpr        -- ^ Body of the binding.
           -> VM ( Inline     -- (1) inline specification for the binding
                 , Bool       -- (2) whether the right-hand side is a scalar computation
                 , CoreExpr)  -- (3) the vectorised right-hand side
vectTopRhs recFs var expr
  = closedV
  $ do { globalScalar <- isGlobalScalarVar var
       ; vectDecl     <- lookupVectDecl var
       ; let isDFun = isDFunId var

       ; traceVt ("vectTopRhs of " ++ show var ++ info globalScalar isDFun vectDecl ++ ":") $ 
           ppr expr

       ; rhs globalScalar isDFun vectDecl
       }
  where
    rhs _globalScalar _isDFun (Just (_, expr'))               -- Case (1)
      = return (inlineMe, False, expr')
    rhs True          False   Nothing                         -- Case (2)
      = do { expr' <- vectScalarFun True recFs expr
           ; return (inlineMe, True, vectorised expr')
           }
    rhs True          True    Nothing                         -- Case (3)
      = do { expr' <- vectScalarDFun var recFs
           ; return (DontInline, True, expr')
           }
    rhs False         False   Nothing                         -- Case (4) — not a dfun
      = do { let exprFvs = freeVars expr
           ; (inline, isScalar, vexpr) 
               <- inBind var $
                    vectPolyExpr (isStrongLoopBreaker $ idOccInfo var) recFs exprFvs
           ; return (inline, isScalar, vectorised vexpr)
           }
    rhs False         True    Nothing                         -- Case (4) — is a dfun
      = do { expr' <- vectDictExpr expr
           ; return  (DontInline, True, expr')
           }

    info True  False _                          = " [VECTORISE SCALAR]"
    info True  True  _                          = " [VECTORISE SCALAR instance]"
    info False _     vectDecl | isJust vectDecl = " [VECTORISE]"
                              | otherwise       = " (no pragma)"

-- |Project out the vectorised version of a binding from some closure,
-- or return the original body if that doesn't work or the binding is scalar. 
--
tryConvert :: Var       -- ^ Name of the original binding (eg @foo@)
           -> Var       -- ^ Name of vectorised version of binding (eg @$vfoo@)
           -> CoreExpr  -- ^ The original body of the binding.
           -> VM CoreExpr
tryConvert var vect_var rhs
  = do { globalScalar <- isGlobalScalarVar var
       ; if globalScalar
         then
           return rhs
         else
           fromVect (idType var) (Var vect_var) 
           `orElseErrV` 
           do { emitVt "  Could NOT call vectorised from original version" $ ppr var
              ; return rhs
              }
       }