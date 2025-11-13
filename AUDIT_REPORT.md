# Informe de Análisis de Amenazas y Preparación para Auditoría: KipuBankV3

**Fecha:** 12 de noviembre de 2025
**Para:** Equipo de Desarrollo de KipuBank
**De:** Fabian Rivertt
**Asunto:** Análisis de amenazas y preparación para la auditoría de `KipuBankV3`

---

## 1. Descripción General de KipuBankV3

`KipuBankV3` es una bóveda de finanzas descentralizadas (DeFi) diseñada para consolidar depósitos en un solo activo: USDC.

A diferencia de su predecesor, `KipuBankV3` interactúa con el protocolo Uniswap V2 para aceptar una gama más amplia de activos. La lógica central del protocolo es la siguiente:

1.  **Depósito de USDC:** Si un usuario deposita USDC, el token se transfiere directamente y se acredita a su balance.
2.  **Depósito de ETH:** Si un usuario deposita ETH nativo, el contrato lo envuelve (implícitamente a través del Router) y ejecuta un swap de `WETH -> USDC`. El monto de USDC resultante se acredita al usuario.
3.  **Depósito de otros ERC20:** Si un usuario deposita cualquier otro token ERC20 (ej. DAI, WETH), el contrato ejecuta un swap de `TokenIn -> USDC`. El monto de USDC resultante se acredita al usuario.
4.  **Límite (Bank Cap):** Todos los depósitos se validan contra un `s_bankCapUsd`, que limita el valor total de USDC que el contrato puede mantener.
5.  **Retiros:** Los usuarios solo pueden retirar sus balances en USDC.

El objetivo es simplificar la gestión de la bóveda a un solo activo (USDC) y, al mismo tiempo, mejorar la experiencia del usuario al permitir depósitos en múltiples divisas.

---

## 2. Evaluación de Madurez del Protocolo

El protocolo `KipuBankV3` es un prototipo funcional (PoC) robusto, pero la cobertura de pruebas actual revela debilidades significativas que impiden su paso a producción.

- **Cobertura de Pruebas:** La cobertura de pruebas actual, obtenida mediante `forge coverage --fork-url $SEPOLIA_RPC_URL`, es **insuficiente** para un contrato de esta criticidad.

  | Archivo              | % Líneas   | % Declaraciones | % Ramas (Branches) | % Funciones |
  | :------------------- | :--------- | :-------------- | :----------------- | :---------- |
  | `src/KipuBankV3.sol` | **64.04%** | 59.05%          | **21.05%**         | **100.00%** |
  | **Total**            | 27.14%     | 28.18%          | 8.89%              | 27.59%      |

  El **100% de cobertura de funciones** es un buen comienzo, ya que confirma que todas las funciones (`depositETH`, `withdrawUSDC`, etc.) fueron _llamadas_ al menos una vez por nuestras 6 pruebas.

  Sin embargo, la cobertura de **Ramas (Branches) del 21.05% (4/19)** es una **bandera roja crítica**. Esto demuestra que nuestras pruebas actuales (principalmente "rutas felices") no están validando la gran mayoría de las bifurcaciones lógicas y casos de esquina (los `if`, `revert`, etc.) dentro del contrato.

- **Métodos de Prueba:**

  - **Utilizados:** Pruebas unitarias de _forking_. Todas las 6 pruebas pasan (`Suite result: ok. 6 passed`), validando la funcionalidad central.
  - **Debilidad (Dependencia de Forking):** Las pruebas fallan catastróficamente (`[FAIL: EvmError: Revert] setUp()`) si se ejecutan con `forge coverage` sin la bandera `--fork-url`. Esto demuestra que el conjunto de pruebas **depende 100% de un estado de red bifurcado** (para los _cheatcodes_ `deal` y `vm.deal`). El protocolo carece de pruebas unitarias puras que utilicen _mocks_ (simulaciones) del Router de Uniswap y de USDC.
  - **Faltantes:**
    1.  **Pruebas de Fuzzing:** No se han realizado pruebas de _fuzzing_ en las funciones de depósito con una amplia gama de `uint256` para `_amount`, o con tokens ERC20 que tengan propiedades anómalas (ej. tokens con tarifa, tokens de rebase).
    2.  **Pruebas de Invariantes:** No se ha implementado un conjunto de pruebas de invariantes (ver Sección 6).

- **Documentación:**

  - **NatSpec:** La documentación en el código es completa y clara.
  - **README:** El `README.md` principal explica bien la configuración y el despliegue.
  - **Faltante:** No existe una documentación técnica formal (ej. "GitBook") que explique los riesgos para el usuario, los supuestos del protocolo y los detalles de la arquitectura.

- **Roles y Poderes de los Actores:**
  - El protocolo tiene un solo rol privilegiado: `DEFAULT_ADMIN_ROLE` (el "Owner").
  - **Poder Crítico:** Este rol tiene un poder singular y absoluto: `setBankCap()`.
  - **Debilidad:** Esta es una capacidad de alto riesgo y centralizada. Una clave de administrador comprometida podría llamar a `setBankCap(0)`, bloqueando permanentemente todos los depósitos futuros. No existe un `Timelock` (bloqueo de tiempo) o una gobernanza (Multisig) para esta acción.

---

## 3. Vectores de Ataque y Modelo de Amenazas

Se identifican tres superficies de ataque principales:

### Ataque 1: (Abuso de Supuestos) - Fallo de Suposición de "Ruta Directa"

- **Escenario:** Un usuario intenta depositar un token `XYZ` que es legítimo pero "exótico". Este token solo tiene un par de liquidez `XYZ/WETH` en Uniswap V2, pero no un par `XYZ/USDC`.
- **Lógica del Ataque:** El contrato `KipuBankV3` asume (en la línea 142) que siempre existe una ruta directa `[TokenIn, USDC]`. Al construir esta ruta `[XYZ, USDC]` y llamar a `uniswapRouter.getAmountsOut()`, la llamada revertirá dentro de la librería de Uniswap.
- **Impacto:** Este no es un ataque de robo de fondos, sino un **fallo de lógica de negocio y un vector de Denegación de Servicio (DoS)** para la mayoría de los tokens. La promesa de "aceptar cualquier token" es funcionalmente falsa; el contrato solo acepta USDC, ETH y tokens con un par USDC directo.

### Ataque 2: (Estrategia Económica) - Manipulación de Oráculo y Slippage Fijo

- **Escenario:** Un atacante (ej. un bot de MEV) monitorea el mempool y ve una transacción grande de un usuario, por ejemplo, `depositETH(100 ETH)`.
- **Lógica del Ataque:**
  1.  **Front-run:** El atacante compra una gran cantidad de USDC del par `WETH/USDC`, empeorando el precio del WETH.
  2.  **Ejecución:** La transacción del usuario se ejecuta. Sus 100 ETH se intercambian por _menos_ USDC de lo que esperaban.
  3.  **Back-run:** El atacante vende su USDC de nuevo al par, obteniendo más WETH del que tenía al principio, a expensas del usuario.
- **Debilidad del Protocolo:** El contrato `KipuBankV3` impone una tolerancia de _slippage_ (deslizamiento) fija y ciega del **0.5%** (línea 153: `minOut = (expectedUsdcOut * 995) / 1000`). El usuario no puede controlar esto.
- **Impacto:** El protocolo permite "legalmente" que los atacantes de sándwich drenen hasta el 0.5% del valor de **cada** depósito que no sea de USDC. Esto es un drenaje de valor predecible e inevitable para el usuario.

### Ataque 3: (Control de Acceso) - Abuso del Rol de Administrador Centralizado

- **Escenario:** La clave privada del `DEFAULT_ADMIN_ROLE` es robada o comprometida.
- **Lógica del Ataque:** El atacante tiene un solo poder: `setBankCap(uint256 _newCapUsd)`.
- **Impacto (DoS):** El atacante llama a `setBankCap(0)`. El contrato ahora tiene un límite de 0. Asumiendo que `s_totalUsdDeposited` ya es > 0, cualquier nuevo depósito fallará la validación del `bankCap`. Esto **bloquea permanentemente todos los depósitos futuros**, matando efectivamente el protocolo.

---

## 4. Especificación de Invariantes

Los invariantes son propiedades que _siempre_ deben ser verdaderas. Si alguna vez se rompen, el protocolo es fallido o está siendo explotado.

- **Invariante 1: Conservación de Valor Interno**

  > La suma de todos los balances de USDC de los usuarios en el `mapping s_usdcBalances` debe ser siempre exactamente igual a la variable de estado `s_totalUsdDeposited`.
  > `sum(s_usdcBalances[user_i]) == s_totalUsdDeposited`

- **Invariante 2: Cumplimiento del Límite del Banco (Bank Cap)**

  > La cantidad total de USDC registrada en `s_totalUsdDeposited` nunca debe superar el límite `s_bankCapUsd`.
  > `s_totalUsdDeposited <= s_bankCapUsd`

- **Invariante 3: Solvencia del Contrato**
  > El balance real de USDC que posee el contrato (`usdc.balanceOf(address(this))`) debe ser siempre mayor o igual al total de depósitos registrados que se deben a los usuarios (`s_totalUsdDeposited`).
  > `usdc.balanceOf(address(this)) >= s_totalUsdDeposited` > _(Deberían ser iguales, pero `>=` es más seguro por si alguien envía USDC directamente al contrato sin usar una función)._

---

## 5. Impacto de las Violaciones de Invariantes

- **Violación del Invariante 1:** Si `sum(balances) > totalDeposited`, el contrato ha prometido más dinero del que cree tener. Si `totalDeposited > sum(balances)`, los fondos de los usuarios están bloqueados permanentemente. Ambos escenarios son **catastróficos** y apuntan a un error de contabilidad.
- **Violación del Invariante 2:** Si `totalDeposited > bankCap`, la promesa fundamental de gestión de riesgos del protocolo se ha roto. Esto indica un fallo en la lógica de validación previa al depósito. **Impacto Crítico.**
- **Violación del Invariante 3:** Si `usdc.balanceOf(this) < totalDeposited`, el banco es insolvente. Los usuarios no pueden retirar sus fondos. Esto podría ocurrir si la lógica del swap calcula mal el `usdcReceived` o si un token malicioso (ej. con tarifa) rompe la lógica de contabilidad. **Impacto Catastrófico (Bank Run).**

---

## 6. Recomendaciones

Se deben implementar **Pruebas de Invariantes** formales usando el framework de Foundry para mejorar la cobertura.

1.  Crear un nuevo contrato de prueba `Invariance.t.sol` que herede de `Test`.
2.  Crear un _handler_ que mantenga un estado de los balances de los usuarios (ej. `mapping(address => uint256) internal balances`).
3.  Escribir funciones `depositETH()`, `depositUSDC()`, `depositOtherToken()`, `withdrawUSDC()` y `setCap()` en el _handler_. Estas funciones llamarán aleatoriamente a las funciones reales del contrato `KipuBankV3` con actores y montos aleatorios.
4.  **Validar Invariante 1 y 2:** Después de cada llamada en el _handler_, escribir la función `invariant_balancesMustMatchCap()` y hacer `assertEq(bank.getTotalUsdDeposited(), totalBalancesEnHandler)` y `assertTrue(bank.getTotalUsdDeposited() <= bank.getBankCap())`.
5.  **Validar Invariante 3:** Escribir la función `invariant_contractMustBeSolvent()` y hacer `assertTrue(usdc.balanceOf(address(bank)) >= bank.getTotalUsdDeposited())`.
6.  Ejecutar estas pruebas de invariantes con un alto número de iteraciones (`--fuzz-runs 10000`).
7.  **Pruebas de Fuzzing Específicas:** Fuzzear `depositERC20` con tokens que implementen tarifas de transferencia (fee-on-transfer) o sean de rebase (rebasing) para intentar romper el Invariante 3. Esto mejorará la cobertura de Ramas (Branches).

---

## 7. Conclusión y Próximos Pasos

`KipuBankV3` es un excelente prototipo, pero la baja cobertura de pruebas (especialmente de Ramas con 21.05%) y los vectores de ataque identificados demuestran que **no está listo para auditoría** y mucho menos para mainnet.

**Acciones Requeridas para la Madurez del Protocolo:**

1.  **Aumentar Cobertura de Pruebas:** Implementar las pruebas de Fuzzing e Invariantes (Sección 6) para cubrir las 15 ramas lógicas faltantes (`if`/`revert`) y alcanzar una cobertura >90%.
2.  **Mitigar Ataque 3 (Admin):** El poder `setBankCap()` debe ser transferido del `DEFAULT_ADMIN_ROLE` a un contrato `Timelock` (ej. 48 horas de retraso) o a una Multisig (ej. 3 de 5 firmas).
3.  **Mitigar Ataque 2 (Slippage):** Refactorizar `depositETH` y `depositERC20` para que acepten un parámetro `uint256 _minAmountOut` del usuario. Esto permite al usuario establecer su propia tolerancia al slippage.
4.  **Mitigar Ataque 1 (Ruta Directa):** Re-diseñar la lógica de swap. El contrato no debe construir el `path`. Debe tomar un `bytes memory _swapData` como argumento, permitiendo al usuario (o a un router fuera de la cadena) construir una ruta multi-hop (`Token -> WETH -> USDC`).

Una vez que estos cuatro puntos se hayan abordado, el protocolo será significativamente más seguro, descentralizado y robusto, y estará en una posición mucho más fuerte para someterse a una auditoría profesional.
