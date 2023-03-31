// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "../interfaces/ITetuVaultV2.sol";
import "../interfaces/IForwarder.sol";
import "../interfaces/IController.sol";
import "../interfaces/ITetuLiquidator.sol";
import "../proxy/ControllableV3.sol";

/// @title Gelato resolver for distribute pending tokens in ForwarderV3
/// @author belbix
contract ForwarderDistributeResolver is ControllableV3 {
  // --- CONSTANTS ---

  string public constant VERSION = "1.0.0";
  uint public constant DELAY_RATE_DENOMINATOR = 100_000;

  // --- VARIABLES ---

  address public owner;
  address public pendingOwner;
  uint public delay;
  uint public maxGas;
  uint public maxCallsPerCall;

  mapping(address => uint) public delayRate;
  mapping(address => uint) public lastCallPerVault;
  mapping(address => bool) public operators;
  mapping(address => bool) public excludedVaults;
  uint public lastCall;
  IForwarder public forwarder;
  ITetuLiquidator public liquidator;
  address public tetuToken;

  // --- INIT ---

  function init(address controller_) external initializer {
    ControllableV3.__Controllable_init(controller_);

    owner = msg.sender;
    delay = 1 days;
    maxGas = 200 gwei;
    maxCallsPerCall = 5;
    forwarder = IForwarder(IController(controller_).forwarder());
    liquidator = ITetuLiquidator(IController(controller_).liquidator());
  }

  modifier onlyOwner() {
    require(msg.sender == owner, "!owner");
    _;
  }

  // --- OWNER FUNCTIONS ---

  function offerOwnership(address value) external onlyOwner {
    pendingOwner = value;
  }

  function acceptOwnership() external {
    require(msg.sender == pendingOwner, "!pendingOwner");
    owner = pendingOwner;
    pendingOwner = address(0);
  }

  function setDelay(uint value) external onlyOwner {
    delay = value;
  }

  function setMaxGas(uint value) external onlyOwner {
    maxGas = value;
  }

  function setMaxCallsPerCall(uint value) external onlyOwner {
    maxCallsPerCall = value;
  }

  function setDelayRate(address[] memory _vaults, uint value) external onlyOwner {
    for (uint i; i < _vaults.length; ++i) {
      delayRate[_vaults[i]] = value;
    }
  }

  function changeOperatorStatus(address operator, bool status) external onlyOwner {
    operators[operator] = status;
  }

  function changeVaultExcludeStatus(address[] memory _vaults, bool status) external onlyOwner {
    for (uint i; i < _vaults.length; ++i) {
      excludedVaults[_vaults[i]] = status;
    }
  }

  // --- MAIN LOGIC ---

  function getLastCall(address vault) public view returns (uint lastCallTimestamp) {
    return lastCallPerVault[vault];
  }

  function isReadyToDistribute(address vault, IForwarder _forwarder, ITetuLiquidator _liquidator, address tetu, uint threshold) public view returns (bool) {
    uint rtLength = _forwarder.tokenPerDestinationLength(vault);
    uint tetuAmountOut;
    for (uint i; i < rtLength; ++i) {
      address rt = _forwarder.tokenPerDestinationAt(vault, i);
      uint rtAmount = _forwarder.amountPerDestination(rt, vault);
      tetuAmountOut += _liquidator.getPrice(rt, tetu, rtAmount);
    }
    return tetuAmountOut > threshold;
  }

  function call(address[] memory _vaults) external returns (uint amountOfCalls) {
    require(operators[msg.sender], "!operator");

    uint _maxHwPerCall = maxCallsPerCall;
    uint vaultsLength = _vaults.length;
    uint counter;
    IForwarder _forwarder = forwarder;
    for (uint i; i < vaultsLength; ++i) {
      address vault = _vaults[i];

      try _forwarder.distributeAll(vault) {
        lastCallPerVault[vault] = block.timestamp;
      } catch Error(string memory _err) {
        revert(string(abi.encodePacked("Vault error: 0x", _toAsciiString(vault), " ", _err)));
      } catch (bytes memory _err) {
        revert(string(abi.encodePacked("Vault low-level error: 0x", _toAsciiString(vault), " ", string(_err))));
      }
      counter++;
      if (counter >= _maxHwPerCall) {
        break;
      }
    }

    lastCall = block.timestamp;
    return counter;
  }

  function maxGasAdjusted() public view returns (uint) {
    uint _maxGas = maxGas;

    uint diff = block.timestamp - lastCall;
    uint multiplier = diff * 100 / 1 days;
    return _maxGas + _maxGas * multiplier / 100;
  }

  function checker() external view returns (bool canExec, bytes memory execPayload) {
    if (tx.gasprice > maxGasAdjusted()) {
      return (false, abi.encodePacked("Too high gas: ", _toString(tx.gasprice / 1e9)));
    }

    IController _controller = IController(controller());
    uint _delay = delay;
    uint vaultsLength = _controller.vaultsListLength();
    address[] memory _vaults = new address[](vaultsLength);
    IForwarder _forwarder = forwarder;
    ITetuLiquidator _liquidator = liquidator;
    address tetu = _forwarder.tetu();
    uint threshold = _forwarder.tetuThreshold();
    uint counter;
    for (uint i; i < vaultsLength; ++i) {
      address vault = _controller.vaults(i);
      if (!excludedVaults[vault] && isReadyToDistribute(vault, _forwarder, _liquidator, tetu, threshold)) {
        uint delayAdjusted = _delay;
        uint _delayRate = delayRate[vault];
        if (_delayRate != 0) {
          delayAdjusted = _delay * _delayRate / DELAY_RATE_DENOMINATOR;
        }

        if (getLastCall(vault) + delayAdjusted < block.timestamp) {
          _vaults[i] = vault;
          counter++;
        }
      }
    }
    if (counter == 0) {
      return (false, bytes("No ready vaults"));
    } else {
      address[] memory vaultsResult = new address[](counter);
      uint j;
      for (uint i; i < vaultsLength; ++i) {
        if (_vaults[i] != address(0)) {
          vaultsResult[j] = _vaults[i];
          ++j;
        }
      }
      return (true, abi.encodeWithSelector(ForwarderDistributeResolver.call.selector, vaultsResult));
    }
  }

  /// @dev Inspired by OraclizeAPI's implementation - MIT license
  ///      https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol
  function _toString(uint value) internal pure returns (string memory) {
    if (value == 0) {
      return "0";
    }
    uint temp = value;
    uint digits;
    while (temp != 0) {
      digits++;
      temp /= 10;
    }
    bytes memory buffer = new bytes(digits);
    while (value != 0) {
      digits -= 1;
      buffer[digits] = bytes1(uint8(48 + uint(value % 10)));
      value /= 10;
    }
    return string(buffer);
  }

  function _toAsciiString(address x) internal pure returns (string memory) {
    bytes memory s = new bytes(40);
    for (uint i = 0; i < 20; i++) {
      bytes1 b = bytes1(uint8(uint(uint160(x)) / (2 ** (8 * (19 - i)))));
      bytes1 hi = bytes1(uint8(b) / 16);
      bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
      s[2 * i] = _char(hi);
      s[2 * i + 1] = _char(lo);
    }
    return string(s);
  }

  function _char(bytes1 b) internal pure returns (bytes1 c) {
    if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
    else return bytes1(uint8(b) + 0x57);
  }
}
