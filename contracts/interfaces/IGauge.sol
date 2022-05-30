// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

interface IGauge {

  function getReward(
    address stakingToken,
    address account,
    address[] memory tokens
  ) external;

  function getAllRewards(
    address stakingToken,
    address account
  ) external;

  function getAllRewardsForTokens(
    address[] memory stakingTokens,
    address account
  ) external;

  function attachVe(address stakingToken, address account, uint veId) external;

  function detachVe(address stakingToken, address account, uint veId) external;

  function handleBalanceChange(address account) external;

  function notifyRewardAmount(address stakingToken, address token, uint amount) external;

}
