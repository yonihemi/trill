//
//  BaseSema.swift
//  Trill
//

import Foundation

enum SemaError: Error, CustomStringConvertible {
  case unknownFunction(name: Identifier)
  case unknownType(type: DataType)
  case callNonFunction(type: DataType?)
  case unknownField(typeDecl: TypeDecl, expr: FieldLookupExpr)
  case unknownVariableName(name: Identifier)
  case invalidOperands(op: BuiltinOperator, invalid: DataType)
  case cannotSubscript(type: DataType)
  case cannotCoerce(type: DataType, toType: DataType)
  case varArgsInNonForeignDecl
  case foreignFunctionWithBody(name: Identifier)
  case nonForeignFunctionWithoutBody(name: Identifier)
  case foreignVarWithRHS(name: Identifier)
  case dereferenceNonPointer(type: DataType)
  case cannotSwitch(type: DataType)
  case nonPointerNil(type: DataType)
  case notAllPathsReturn(type: DataType)
  case noViableOverload(name: Identifier, args: [Argument])
  case candidates([FuncDecl])
  case ambiguousReference(name: Identifier)
  case addressOfRValue
  case breakNotAllowed
  case continueNotAllowed
  case fieldOfFunctionType(type: DataType)
  case duplicateMethod(name: Identifier, type: DataType)
  case duplicateField(name: Identifier, type: DataType)
  case referenceSelfInProp(name: Identifier)
  case poundFunctionOutsideFunction
  case assignToConstant(name: Identifier?)
  case deinitOnStruct(name: Identifier?)
  case indexIntoNonTuple
  case outOfBoundsTupleField(field: Int, max: Int)
  
  var description: String {
    switch self {
    case .unknownFunction(let name):
      return "unknown function '\(name)'"
    case .unknownType(let type):
      return "unknown type '\(type)'"
    case .unknownVariableName(let name):
      return "unknown variable '\(name)'"
    case .unknownField(let typeDecl, let expr):
      return "unknown field name '\(expr.name)' in type '\(typeDecl.type)'"
    case .invalidOperands(let op, let invalid):
      return "invalid argument for operator '\(op)' (got '\(invalid)')"
    case .cannotSubscript(let type):
      return "cannot subscript value of type '\(type)'"
    case .cannotCoerce(let type, let toType):
      return "cannot coerce '\(type)' to '\(toType)'"
    case .cannotSwitch(let type):
      return "cannot switch over values of type '\(type)'"
    case .foreignFunctionWithBody(let name):
      return "foreign function '\(name)' cannot have a body"
    case .nonForeignFunctionWithoutBody(let name):
      return "function '\(name)' must have a body"
    case .foreignVarWithRHS(let name):
      return "foreign var '\(name)' cannot have a value"
    case .varArgsInNonForeignDecl:
      return "varargs in non-foreign declarations are not yet supported"
    case .nonPointerNil(let type):
      return "cannot set non-pointer type '\(type)' to nil"
    case .dereferenceNonPointer(let type):
      return "cannot dereference a value of non-pointer type '\(type)'"
    case .addressOfRValue:
      return "cannot get address of an r-value"
    case .breakNotAllowed:
      return "'break' not allowed outside loop"
    case .continueNotAllowed:
      return "'continue' not allowed outside loop"
    case .notAllPathsReturn(let type):
      return "missing return in a function expected to return \(type)"
    case .noViableOverload(let name, let args):
      var s = "could not find a viable overload for \(name) with arguments of type ("
      s += args.map {
        var d = ""
        if let label = $0.label {
          d += "\(label): "
        }
        if let t = $0.val.type {
          d += "\(t)"
        } else {
          d += "<<error type>>"
        }
        return d
        }.joined(separator: ", ")
      s += ")"
      return s
    case .candidates(let functions):
      var s = "found candidates with these arguments: "
      s += functions.map { $0.formattedParameterList }.joined(separator: ", ")
      return s
    case .ambiguousReference(let name):
      return "ambiguous reference to '\(name)'"
    case .callNonFunction(let type):
      return "cannot call non-function type '" + (type.map { String(describing: $0) } ?? "<<error type>>") + "'"
    case .fieldOfFunctionType(let type):
      return "cannot find field on function of type \(type)"
    case .duplicateMethod(let name, let type):
      return "invalid redeclaration of method '\(name)' on type '\(type)'"
    case .duplicateField(let name, let type):
      return "invalid redeclaration of field '\(name)' on type '\(type)'"
    case .referenceSelfInProp(let name):
      return "type '\(name)' cannot have a property that references itself"
    case .poundFunctionOutsideFunction:
      return "'#function' is only valid inside function scope"
    case .deinitOnStruct(let name):
      return "cannot have a deinitializer in non-indirect type '\(name)'"
    case .assignToConstant(let name):
      let val: String
      if let n = name {
        val = "'\(n)'"
      } else {
        val = "expression"
      }
      return "cannot mutate \(val); expression is a 'let' constant"
    case .indexIntoNonTuple:
      return "cannot index into non-tuple expression"
    case .outOfBoundsTupleField(let field, let max):
      return "cannot access field \(field) in tuple with \(max) fields"
    }
  }
}

class Sema: ASTTransformer, Pass {
  var varBindings = [String: VarAssignDecl]()
  
  var title: String {
    return "Semantic Analysis"
  }
  
  override func run(in context: ASTContext) {
    registerTopLevelDecls(in: context)
    super.run(in: context)
  }
  
  func registerTopLevelDecls(in context: ASTContext) {
    for expr in context.extensions {
      guard let typeDecl = context.decl(for: expr.type) else {
        error(SemaError.unknownType(type: expr.type),
              loc: expr.startLoc(),
              highlights: [ expr.sourceRange ])
        continue
      }
      for method in expr.methods {
        typeDecl.addMethod(method, named: method.name.name)
      }
    }
    for expr in context.types {
      let oldBindings = varBindings
      defer { varBindings = oldBindings }
      var fieldNames = Set<String>()
      for field in expr.fields {
        field.containingTypeDecl = expr
        if fieldNames.contains(field.name.name) {
          error(SemaError.duplicateField(name: field.name,
                                         type: expr.type),
                loc: field.startLoc(),
                highlights: [ expr.name.range ])
          continue
        }
        fieldNames.insert(field.name.name)
      }
      var methodNames = Set<String>()
      for method in expr.methods {
        let mangled = Mangler.mangle(method)
        if methodNames.contains(mangled) {
          error(SemaError.duplicateMethod(name: method.name,
                                          type: expr.type),
                loc: method.startLoc(),
                highlights: [ expr.name.range ])
          continue
        }
        methodNames.insert(mangled)
      }
      if context.isCircularType(expr) {
        error(SemaError.referenceSelfInProp(name: expr.name),
              loc: expr.startLoc(),
              highlights: [
                expr.name.range
          ])
      }
    }
  }
  
  override func visitFuncDecl(_ expr: FuncDecl) {
    super.visitFuncDecl(expr)
    if expr.has(attribute: .foreign) {
      if !expr.isInitializer && expr.body != nil {
        error(SemaError.foreignFunctionWithBody(name: expr.name),
              loc: expr.name.range?.start,
              highlights: [
                expr.name.range
          ])
        return
      }
    } else {
      if !expr.has(attribute: .implicit) && expr.body == nil {
        error(SemaError.nonForeignFunctionWithoutBody(name: expr.name),
              loc: expr.name.range?.start,
              highlights: [
                expr.name.range
          ])
        return
      }
      if expr.hasVarArgs {
        error(SemaError.varArgsInNonForeignDecl,
              loc: expr.startLoc())
        return
      }
    }
    let returnType = expr.returnType.type!
    if !context.isValidType(returnType) {
      error(SemaError.unknownType(type: returnType),
            loc: expr.returnType.startLoc(),
            highlights: [
              expr.returnType.sourceRange
        ])
      return
    }
    if let body = expr.body, !body.hasReturn, returnType != .void, !expr.isInitializer {
      error(SemaError.notAllPathsReturn(type: expr.returnType.type!),
            loc: expr.name.range?.start,
            highlights: [
              expr.name.range,
              expr.returnType.sourceRange
        ])
      return
    }
    if case .deinitializer(let type) = expr.kind,
       let decl = context.decl(for: type, canonicalized: true),
       !decl.isIndirect {
     error(SemaError.deinitOnStruct(name: decl.name))
    }
  }
  
  override func withScope(_ e: CompoundStmt, _ f: () -> Void) {
    let oldVarBindings = varBindings
    super.withScope(e, f)
    varBindings = oldVarBindings
  }
  
  override func visitVarAssignDecl(_ decl: VarAssignDecl) -> Result {
    super.visitVarAssignDecl(decl)
    if let rhs = decl.rhs, decl.has(attribute: .foreign) {
      error(SemaError.foreignVarWithRHS(name: decl.name),
            loc: decl.startLoc(),
            highlights: [ rhs.sourceRange ])
      return
    }
    guard !decl.has(attribute: .foreign) else { return }
    if let type = decl.typeRef?.type {
      if !context.isValidType(type) {
        error(SemaError.unknownType(type: type),
              loc: decl.typeRef!.startLoc(),
              highlights: [
                decl.typeRef!.sourceRange
          ])
        return
      }
      
      if let rhs = decl.rhs, let rhsType = rhs.type {
        if context.canCoerce(rhsType, to: type) {
          rhs.type = type
        }
      }
    }
    if decl.containingTypeDecl == nil {
      varBindings[decl.name.name] = decl
    }
    if let rhs = decl.rhs, decl.typeRef == nil {
      guard let type = rhs.type else { return }
      decl.type = type
      decl.typeRef = type.ref()
    }
  }
  
  override func visitParenExpr(_ expr: ParenExpr) {
    super.visitParenExpr(expr)
    expr.type = expr.value.type
  }
  
  override func visitSizeofExpr(_ expr: SizeofExpr) -> Result {
    let handleVar = { (varExpr: VarExpr) in
      let possibleType = DataType(name: varExpr.name.name)
      if self.context.isValidType(possibleType) {
        expr.valueType = possibleType
      } else {
        super.visitSizeofExpr(expr)
        expr.valueType = varExpr.type
      }
    }
    if let varExpr = expr.value as? VarExpr {
      handleVar(varExpr)
    } else if let varExpr = (expr.value as? ParenExpr)?.rootExpr as? VarExpr {
      handleVar(varExpr)
    } else {
      super.visitSizeofExpr(expr)
      expr.valueType = expr.value!.type
    }
  }
  
  override func visitFuncArgumentAssignDecl(_ decl: FuncArgumentAssignDecl) -> Result {
    super.visitFuncArgumentAssignDecl(decl)
    guard context.isValidType(decl.type) else {
      error(SemaError.unknownType(type: decl.type),
            loc: decl.typeRef?.startLoc(),
            highlights: [
              decl.typeRef?.sourceRange
        ])
      return
    }
    let canTy = context.canonicalType(decl.type)
    if case .custom = canTy,
      context.decl(for: canTy)!.isIndirect {
      decl.mutable = true
    }
    varBindings[decl.name.name] = decl
  }
  
  func candidate(forArgs args: [Argument], candidates: [FuncDecl]) -> FuncDecl? {
    search: for candidate in candidates {
      var candArgs = candidate.args
      if let first = candArgs.first, first.isImplicitSelf {
        candArgs.remove(at: 0)
      }
      if !candidate.hasVarArgs && candArgs.count != args.count { continue }
      for (candArg, exprArg) in zip(candArgs, args) {
        if let externalName = candArg.externalName, exprArg.label != externalName { continue search }
        guard var valType = exprArg.val.type else { continue search }
        let type = context.canonicalType(candArg.type)
        // automatically coerce number literals.
        if case .int = type, exprArg.val is NumExpr {
          valType = type
          exprArg.val.type = valType
        } else if context.canBeNil(type), exprArg.val is NilExpr {
          valType = type
          exprArg.val.type = valType
        }
        if !matches(type, .any) && !matches(type, valType) {
          continue search
        }
      }
      return candidate
    }
    return nil
  }
  
  override func visitFieldLookupExpr(_ expr: FieldLookupExpr) {
    _ = visitFieldLookupExpr(expr, callArgs: nil)
  }
  
  /// - returns: true if the resulting decl is a field of function type,
  ///           instead of a method
  func visitFieldLookupExpr(_ expr: FieldLookupExpr, callArgs: [Argument]?) -> Bool {
    super.visitFieldLookupExpr(expr)
    guard let type = expr.lhs.type else {
      // An error will already have been thrown from here
      return false
    }
    if case .function = type {
      error(SemaError.fieldOfFunctionType(type: type),
            loc: expr.startLoc(),
            highlights: [
              expr.sourceRange
        ])
      return false
    }
    guard let typeDecl = context.decl(for: type) else {
      error(SemaError.unknownType(type: type.rootType),
            loc: expr.startLoc(),
            highlights: [
              expr.sourceRange
        ])
      return false
    }
    expr.typeDecl = typeDecl
    let candidateMethods = typeDecl.methods(named: expr.name.name)
    if let callArgs = callArgs,
       let index = typeDecl.indexOf(fieldName: expr.name) {
      let field = typeDecl.fields[index]
      if case .function(let args, _) = field.type {
        let types = callArgs.flatMap { $0.val.type }
        if types.count == callArgs.count && args == types {
          expr.decl = field
          expr.type = field.type
          return true
        }
      }
    }
    if let decl = typeDecl.field(named: expr.name.name) {
      expr.decl = decl
      expr.type = decl.type
      return true
    } else if !candidateMethods.isEmpty {
      if let args = callArgs,
         let funcDecl = candidate(forArgs: args, candidates: candidateMethods) {
        expr.decl = funcDecl
        let types = funcDecl.args.map { $0.type }
        expr.type = .function(args: types, returnType: funcDecl.returnType.type!)
        return false
      } else {
        error(SemaError.ambiguousReference(name: expr.name),
              loc: expr.startLoc(),
              highlights: [
                expr.sourceRange
          ])
        return false
      }
    } else {
      error(SemaError.unknownField(typeDecl: typeDecl, expr: expr),
            loc: expr.startLoc(),
            highlights: [ expr.name.range ])
      return false
    }
  }
  
  override func visitTupleFieldLookupExpr(_ expr: TupleFieldLookupExpr) -> Result {
    super.visitTupleFieldLookupExpr(expr)
    guard let lhsTy = expr.lhs.type else { return }
    let lhsCanTy = context.canonicalType(lhsTy)
    guard case .tuple(let fields) = lhsCanTy else {
      error(SemaError.indexIntoNonTuple,
            loc: expr.startLoc(),
            highlights: [
              expr.sourceRange
            ])
      return
    }
    if expr.field >= fields.count {
      error(SemaError.outOfBoundsTupleField(field: expr.field, max: fields.count),
            loc: expr.fieldRange.start,
            highlights: [
              expr.fieldRange
            ])
      return
    }
    expr.type = fields[expr.field]
  }
  
  override func visitSubscriptExpr(_ expr: SubscriptExpr) -> Result {
    super.visitSubscriptExpr(expr)
    guard let type = expr.lhs.type else { return }
    guard case .pointer(let subtype) = type else {
      error(SemaError.cannotSubscript(type: type),
            loc: expr.startLoc(),
            highlights: [ expr.lhs.sourceRange ])
      return
    }
    expr.type = subtype
  }
  
  override func visitExtensionDecl(_ expr: ExtensionDecl) -> Result {
    guard let decl = context.decl(for: expr.type) else {
      error(SemaError.unknownType(type: expr.type),
            loc: expr.startLoc(),
            highlights: [ expr.typeRef.name.range ])
      return
    }
    withTypeDecl(decl) {
      super.visitExtensionDecl(expr)
    }
    expr.typeDecl = decl
  }
  
  override func visitVarExpr(_ expr: VarExpr) -> Result {
    super.visitVarExpr(expr)
    if
      let fn = currentFunction,
      fn.isInitializer,
      expr.name == "self" {
      expr.decl = VarAssignDecl(name: "self", typeRef: fn.returnType)
      expr.isSelf = true
      expr.type = fn.returnType.type!
      return
    }
    let candidates = context.functions(named: expr.name)
    if let decl = varBindings[expr.name.name] ?? context.global(named: expr.name) {
      expr.decl = decl
      expr.type = decl.type
      if let d = decl as? FuncArgumentAssignDecl, d.isImplicitSelf {
        expr.isSelf = true
      }
    } else if !candidates.isEmpty {
      if let funcDecl = candidates.first, candidates.count == 1 {
        expr.decl = funcDecl
        expr.type = funcDecl.type
      } else {
        error(SemaError.ambiguousReference(name: expr.name),
              loc: expr.startLoc(),
              highlights: [
                expr.sourceRange
          ])
        return
      }
    }
    guard let decl = expr.decl else {
      error(SemaError.unknownVariableName(name: expr.name),
            loc: expr.startLoc(),
            highlights: [ expr.sourceRange ])
      return
    }
    if let closure = currentClosure {
      closure.add(capture: decl)
    }
  }
  
  override func visitContinueStmt(_ stmt: ContinueStmt) -> Result {
    if currentBreakTarget == nil {
      error(SemaError.continueNotAllowed,
            loc: stmt.startLoc(),
            highlights: [ stmt.sourceRange ])
    }
  }
  
  override func visitBreakStmt(_ stmt: BreakStmt) -> Result {
    if currentBreakTarget == nil {
      error(SemaError.breakNotAllowed,
            loc: stmt.startLoc(),
            highlights: [ stmt.sourceRange ])
    }
  }
  
  func foreignDecl(args: [DataType], ret: DataType) -> FuncDecl {
    let assigns: [FuncArgumentAssignDecl] = args.map {
      let name = Identifier(name: "__implicit__")
      return FuncArgumentAssignDecl(name: "", type: TypeRefExpr(type: $0, name: name))
    }
    let retName = Identifier(name: "\(ret)")
    let typeRef = TypeRefExpr(type: ret, name: retName)
    return FuncDecl(name: "",
                        returnType: typeRef,
                        args: assigns,
                        body: nil,
                        modifiers: [.foreign, .implicit])
  }
  
  override func visitTypeAliasDecl(_ decl: TypeAliasDecl) -> Result {
    guard let bound = decl.bound.type else { return }
    guard context.isValidType(bound) else {
      error(SemaError.unknownType(type: bound),
            loc: decl.bound.startLoc(),
            highlights: [
              decl.bound.sourceRange
        ])
      return
    }
  }
  
  override func visitFuncCallExpr(_ expr: FuncCallExpr) -> Result {
    expr.args.forEach {
      visit($0.val)
    }
    for arg in expr.args {
      guard arg.val.type != nil else { return }
    }
    var candidates = [FuncDecl]()
    var name: Identifier? = nil
    switch expr.lhs {
    case let lhs as FieldLookupExpr:
      let assignedToField = visitFieldLookupExpr(lhs, callArgs: expr.args)
      guard let typeDecl = lhs.typeDecl else { return }
      if case .function(let args, let ret)? = lhs.type, assignedToField {
        candidates.append(foreignDecl(args: args, ret: ret))
      }
      candidates += typeDecl.methods(named: lhs.name.name)
      name = lhs.name
    case let lhs as VarExpr:
      name = lhs.name
      if let typeDecl = context.decl(for: DataType(name: lhs.name.name)) {
        candidates.append(contentsOf: typeDecl.initializers)
      } else if let varDecl = varBindings[lhs.name.name] {
        let type = context.canonicalType(varDecl.type)
        if case .function(let args, let ret) = type {
          candidates += [foreignDecl(args: args, ret: ret)]
        } else {
          error(SemaError.callNonFunction(type: type),
                loc: lhs.startLoc(),
                highlights: [
                  expr.sourceRange
            ])
          return
        }
      } else {
        candidates += context.functions(named: lhs.name)
      }
    default:
      visit(expr.lhs)
      if case .function(let args, let ret)? = expr.lhs.type {
        candidates += [foreignDecl(args: args, ret: ret)]
      } else {
        error(SemaError.callNonFunction(type: expr.lhs.type ?? .void),
              loc: expr.lhs.startLoc(),
              highlights: [
                expr.lhs.sourceRange
          ])
        return
      }
    }
    guard !candidates.isEmpty else {
      error(SemaError.unknownFunction(name: name!),
            loc: name?.range?.start,
            highlights: [ name?.range ])
      return
    }
    guard let decl = candidate(forArgs: expr.args, candidates: candidates) else {
      error(SemaError.noViableOverload(name: name!,
                                       args: expr.args),
            loc: name?.range?.start,
            highlights: [
              name?.range
        ])
      note(SemaError.candidates(candidates),
           loc: name?.range?.start)
      return
    }
    expr.decl = decl
    expr.type = decl.returnType.type
    
    if let lhs = expr.lhs as? FieldLookupExpr {
      if case .immutable(let culprit) = context.mutability(of: lhs),
        decl.has(attribute: .mutating), decl.parentType != nil {
        error(SemaError.assignToConstant(name: culprit),
              loc: name?.range?.start,
              highlights: [
                name?.range
          ])
        return
      }
    }
  }
  
  override func visitCompoundStmt(_ stmt: CompoundStmt) {
    for (idx, e) in stmt.exprs.enumerated() {
      visit(e)
      let isLast = idx == (stmt.exprs.endIndex - 1)
      let isReturn = e is ReturnStmt
      let isBreak = e is BreakStmt
      let isContinue = e is ContinueStmt
      let isNoReturnFuncCall: Bool = {
        if let c = e as? FuncCallExpr {
          return c.decl?.has(attribute: .noreturn) == true
        }
        return false
      }()
      
      if !stmt.hasReturn {
        if isReturn || isNoReturnFuncCall {
          stmt.hasReturn = true
        } else if let ifExpr = e as? IfStmt,
                  let elseBody = ifExpr.elseBody {
          var hasReturn = true
          for block in ifExpr.blocks where !block.1.hasReturn {
            hasReturn = false
          }
          if hasReturn {
            hasReturn = elseBody.hasReturn
          }
          stmt.hasReturn = hasReturn
        }
      }
      
      if (isReturn || isBreak || isContinue || isNoReturnFuncCall) && !isLast {
        let type =
          isReturn ? "return" :
          isContinue ? "continue" :
          isNoReturnFuncCall ? "call to noreturn function" : "break"
        warning("Code after \(type) will not be executed.",
                loc: e.startLoc(),
                highlights: [ stmt.sourceRange ])
      }
    }
  }
  
  override func visitClosureExpr(_ expr: ClosureExpr) {
    super.visitClosureExpr(expr)
    var argTys = [DataType]()
    for arg in expr.args {
      argTys.append(arg.type)
    }
    expr.type = .function(args: argTys, returnType: expr.returnType.type!)
  }
  
  override func visitSwitchStmt(_ stmt: SwitchStmt) {
    super.visitSwitchStmt(stmt)
    guard let valueType = stmt.value.type else { return }
    for c in stmt.cases {
      let fakeInfix = InfixOperatorExpr(op: .equalTo, lhs: stmt.value, rhs: c.constant)
      guard let t = context.operatorType(fakeInfix, for: c.constant.type!),
               !t.isPointer else {
        error(SemaError.cannotSwitch(type: valueType),
              loc: stmt.value.startLoc(),
              highlights: [ stmt.value.sourceRange ])
        continue
      }
    }
  }
  
  override func visitInfixOperatorExpr(_ expr: InfixOperatorExpr) {
    super.visitInfixOperatorExpr(expr)
    guard var lhsType = expr.lhs.type else { return }
    guard var rhsType = expr.rhs.type else { return }
    
    let canLhs = context.canonicalType(lhsType)
    let canRhs = context.canonicalType(rhsType)
    if case .int = canLhs, expr.rhs is NumExpr {
      expr.rhs.type = lhsType
      rhsType = lhsType
    } else if case .int = canRhs, expr.lhs is NumExpr {
      expr.lhs.type = rhsType
      lhsType = rhsType
    }
    if context.canBeNil(canLhs), expr.rhs is NilExpr {
      expr.rhs.type = lhsType
      rhsType = lhsType
    } else if context.canBeNil(canRhs), expr.lhs is NilExpr {
      expr.lhs.type = rhsType
      lhsType = rhsType
    }
    
    if expr.op.isAssign {
      expr.type = .void
      if case .immutable(let name) = context.mutability(of: expr.lhs) {
        if currentFunction == nil || !currentFunction!.isInitializer {
          error(SemaError.assignToConstant(name: name),
                loc: name?.range?.start,
                highlights: [
                  name?.range
            ])
          return
        }
      }
      if expr.rhs is NilExpr, let lhsType = expr.lhs.type {
        guard context.canBeNil(lhsType) else {
          error(SemaError.nonPointerNil(type: lhsType),
                loc: expr.lhs.startLoc(),
                highlights: [
                  expr.lhs.sourceRange,
                  expr.rhs.sourceRange
            ])
          return
        }
      }
    }
    if case .as = expr.op {
      guard context.isValidType(expr.rhs.type!) else {
        error(SemaError.unknownType(type: expr.rhs.type!),
              loc: expr.rhs.startLoc(),
              highlights: [expr.rhs.sourceRange])
        return
      }
      if !context.canCoerce(canLhs, to: canRhs) {
        error(SemaError.cannotCoerce(type: lhsType, toType: rhsType),
              loc: expr.opRange?.start,
              highlights: [
                expr.lhs.sourceRange,
                expr.opRange,
                expr.rhs.sourceRange
          ])
      }
      expr.type = rhsType
    } else {
      if let exprType = context.operatorType(expr, for: canLhs) {
        expr.type = exprType
      } else {
        expr.type = .void
      }
    }
  }
  
  override func visitTernaryExpr(_ expr: TernaryExpr) -> Result {
    super.visitTernaryExpr(expr)
    expr.type = expr.trueCase.type
  }
  
  override func visitPoundFunctionExpr(_ expr: PoundFunctionExpr) -> Result {
    super.visitPoundFunctionExpr(expr)
    guard let funcDecl = currentFunction else {
      error(SemaError.poundFunctionOutsideFunction,
            loc: expr.startLoc(),
            highlights: [
              expr.sourceRange
        ])
      return
    }
    expr.value = funcDecl.formattedName
  }
  
  override func visitPoundDiagnosticStmt(_ stmt: PoundDiagnosticStmt) {
    if stmt.isError {
      context.diag.error(stmt.text, loc: stmt.content.startLoc(), highlights: [])
    } else {
      context.diag.warning(stmt.text, loc: stmt.content.startLoc(), highlights: [])
    }
  }
  
  override func visitReturnStmt(_ stmt: ReturnStmt) {
    guard let returnType = currentClosure?.returnType.type ?? currentFunction?.returnType.type else { return }
    let canRet = context.canonicalType(returnType)
    if case .int = canRet, stmt.value is NumExpr {
      stmt.value.type = returnType
    }
    if context.canBeNil(canRet), stmt.value is NilExpr {
      stmt.value.type = returnType
    }
    super.visitReturnStmt(stmt)
  }
  
  override func visitPrefixOperatorExpr(_ expr: PrefixOperatorExpr) {
    super.visitPrefixOperatorExpr(expr)
    guard let rhsType = expr.rhs.type else { return }
    guard let exprType = expr.type(forArgType: context.canonicalType(rhsType)) else {
      error(SemaError.invalidOperands(op: expr.op, invalid: rhsType),
            loc: expr.opRange?.start,
            highlights: [
              expr.opRange,
              expr.rhs.sourceRange
        ])
      return
    }
    expr.type = exprType
    if expr.op == .star {
      guard case .pointer = rhsType else {
        error(SemaError.dereferenceNonPointer(type: rhsType),
              loc: expr.opRange?.start,
              highlights: [
                expr.opRange,
                expr.rhs.sourceRange
          ])
        return
      }
    }
    if expr.op == .ampersand {
      guard expr.rhs is VarExpr || expr.rhs is SubscriptExpr || expr.rhs is FieldLookupExpr else {
        error(SemaError.addressOfRValue,
              loc: expr.opRange?.start,
              highlights: [
                expr.opRange,
                expr.rhs.sourceRange
          ])
        return
      }
    }
  }
}
