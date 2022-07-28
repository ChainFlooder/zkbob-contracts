// SPDX-License-Identifier: CC0-1.0

pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "../proxy/EIP1967Admin.sol";
import "../interfaces/IERC677Receiver.sol";

/**
 * @title Recovery
 */
abstract contract Recovery is ERC20, EIP1967Admin {
    event ExecutedRecovery(bytes32 indexed hash, uint256 value);
    event CancelledRecovery(bytes32 indexed hash);
    event RequestedRecovery(
        bytes32 indexed hash, uint256 requestTimestamp, uint256 executionTimestamp, address[] accounts, uint256[] values
    );

    address public recoveryAdmin;

    address public recoveredFundsReceiver;
    uint64 public recoveryLimitPercent;
    uint32 public recoveryRequestTimelockPeriod;

    uint256 public totalRecovered;

    bytes32 public recoveryRequestHash;
    uint256 public recoveryRequestExecutionTimestamp;

    /**
     * @dev Throws if called by any account other than the proxy admin or recovery admin.
     */
    modifier onlyRecoveryAdmin() {
        require(_msgSender() == recoveryAdmin || msg.sender == _admin(), "Recovery: not authorized for recovery");
        _;
    }

    /**
     * @dev Updates the address of the recovery admin account.
     * Callable only by the proxy admin.
     * Recovery admin is only authorized to request/execute/cancel recovery operations.
     * The availability, parameters and impact limits of recovery is controlled by the proxy admin.
     * @param _recoveryAdmin address of the new recovery admin account.
     */
    function setRecoveryAdmin(address _recoveryAdmin) external onlyAdmin {
        recoveryAdmin = _recoveryAdmin;
    }

    /**
     * @dev Updates the address of the recovered funds receiver.
     * Callable only by the proxy admin.
     * Recovered funds receiver will receive ERC20, recovered from lost/unused accounts.
     * If receiver is a smart contract, it must correctly process a ERC677 callback, sent once on the recovery execution.
     * @param _recoveredFundsReceiver address of the new recovered funds receiver.
     */
    function setRecoveredFundsReceiver(address _recoveredFundsReceiver) external onlyAdmin {
        recoveredFundsReceiver = _recoveredFundsReceiver;
    }

    /**
     * @dev Updates the max allowed percentage of total supply, which can be recovered.
     * Limits the impact that could be caused by the recovery admin.
     * Callable only by the proxy admin.
     * @param _recoveryLimitPercent percentage, as a fraction of 1 ether, should be at most 100%.
     * In theory, recovery can exceed total supply, if recovered funds are then lost once again,
     * but in practice, we do not expect totalRecovered to reach such extreme values.
     */
    function setRecoveryLimitPercent(uint64 _recoveryLimitPercent) external onlyAdmin {
        require(_recoveryLimitPercent <= 1 ether, "Recovery: invalid percentage");
        recoveryLimitPercent = _recoveryLimitPercent;
    }

    /**
     * @dev Updates the timelock period between submission of the recovery request and its execution.
     * Any user, who is not willing to accept the recovery, can safely withdraw his tokens within such period.
     * Callable only by the proxy admin.
     * @param _recoveryRequestTimelockPeriod new timelock period in seconds.
     */
    function setRecoveryRequestTimelockPeriod(uint32 _recoveryRequestTimelockPeriod) external onlyAdmin {
        require(_recoveryRequestTimelockPeriod <= 30 days, "Recovery: invalid timelock period");
        recoveryRequestTimelockPeriod = _recoveryRequestTimelockPeriod;
    }

    /**
     * @dev Tells if recovery of funds is available, given the current configuration of recovery parameters.
     * @return true, if at least 1 wei of tokens could be recovered within the available limit.
     */
    function isRecoveryEnabled() external view returns (bool) {
        return totalRecovered < totalSupply() * recoveryLimitPercent / 1 ether;
    }

    /**
     * @dev Creates a request to recover funds from abandoned/unused accounts.
     * Only one request could be active at a time. Any pending request would be cancelled and won't take any effect.
     * Callable only by the proxy admin or recovery admin.
     * @param _accounts list of accounts to recover funds from.
     * @param _values list of max values to recover from each of the specified account.
     */
    function requestRecovery(address[] calldata _accounts, uint256[] calldata _values) external onlyRecoveryAdmin {
        require(_accounts.length == _values.length, "Recovery: different lengths");
        require(_accounts.length > 0, "Recovery: empty accounts");

        bytes32 hash = recoveryRequestHash;
        if (hash != bytes32(0)) {
            emit CancelledRecovery(hash);
        }

        uint256[] memory values = new uint256[](_values.length);

        for (uint256 i = 0; i < _values.length; i++) {
            uint256 balance = balanceOf(_accounts[i]);
            values[i] = balance < _values[i] ? balance : _values[i];
        }

        uint256 executionTimestamp = block.timestamp + recoveryRequestTimelockPeriod;
        hash = keccak256(abi.encode(executionTimestamp, _accounts, values));
        recoveryRequestHash = hash;
        recoveryRequestExecutionTimestamp = executionTimestamp;

        emit RequestedRecovery(hash, block.timestamp, executionTimestamp, _accounts, values);
    }

    /**
     * @dev Executes the request to recover funds from abandoned/unused accounts.
     * Executed request should have exactly the same parameters, as emitted in the RequestedRecovery event.
     * Request could only be executed once configured timelock was surpassed.
     * After execution of the request, total amount of recovered funds should not exceed the configured percentage.
     * Callable only by the proxy admin or recovery admin.
     * @param _accounts list of accounts to recover funds from.
     * @param _values list of max values to recover from each of the specified account.
     */
    function executeRecovery(address[] calldata _accounts, uint256[] calldata _values) external onlyRecoveryAdmin {
        uint256 executionTimestamp = recoveryRequestExecutionTimestamp;
        require(executionTimestamp > 0, "Recovery: no active recovery request");
        require(executionTimestamp <= block.timestamp, "Recovery: request still timelocked");

        bytes32 storedHash = recoveryRequestHash;
        bytes32 receivedHash = keccak256(abi.encode(executionTimestamp, _accounts, _values));
        require(storedHash == receivedHash, "Recovery: request hashes do not match");

        uint256 value = _recoverTokens(_accounts, _values);
        totalRecovered += value;

        require(
            totalRecovered < totalSupply() * recoveryLimitPercent / 1 ether, "Recovery: exceed recovery limit percent"
        );

        delete recoveryRequestHash;
        delete recoveryRequestExecutionTimestamp;
        emit ExecutedRecovery(storedHash, value);
    }

    /**
     * @dev Cancels pending recovery request.
     * Callable only by the proxy admin or recovery admin.
     */
    function cancelRecovery() external onlyRecoveryAdmin {
        bytes32 hash = recoveryRequestHash;
        require(hash != bytes32(0), "Recovery: no active recovery request");

        delete recoveryRequestHash;
        delete recoveryRequestExecutionTimestamp;

        emit CancelledRecovery(hash);
    }

    function _recoverTokens(address[] calldata _accounts, uint256[] calldata _values) internal returns (uint256) {
        uint256 total = 0;
        address receiver = recoveredFundsReceiver;

        for (uint256 i = 0; i < _accounts.length; i++) {
            uint256 balance = balanceOf(_accounts[i]);
            uint256 value = balance < _values[i] ? balance : _values[i];
            total += value;

            _transfer(_accounts[i], receiver, value);
        }

        if (Address.isContract(receiver)) {
            require(IERC677Receiver(receiver).onTokenTransfer(address(this), total, new bytes(0)));
        }

        return total;
    }
}
