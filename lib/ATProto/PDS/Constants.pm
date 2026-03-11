package ATProto::PDS::Constants;

use v5.34;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
  ACTION_TOKEN_ACCOUNT_DELETE
  ACTION_TOKEN_EMAIL_CONFIRM
  ACTION_TOKEN_EMAIL_UPDATE
  ACTION_TOKEN_PASSWORD_RESET
  ACTION_TOKEN_PLC_OPERATION
  EVENT_TYPE_ACCOUNT
  EVENT_TYPE_COMMIT
  EVENT_TYPE_IDENTITY
  EVENT_TYPE_SYNC
  TOKEN_AUD_ACCESS
  TOKEN_AUD_REFRESH
);

use constant TOKEN_AUD_ACCESS => 'access';
use constant TOKEN_AUD_REFRESH => 'refresh';

use constant ACTION_TOKEN_PASSWORD_RESET => 'password_reset';
use constant ACTION_TOKEN_EMAIL_CONFIRM  => 'email_confirm';
use constant ACTION_TOKEN_EMAIL_UPDATE   => 'email_update';
use constant ACTION_TOKEN_ACCOUNT_DELETE => 'account_delete';
use constant ACTION_TOKEN_PLC_OPERATION  => 'plc_operation';

use constant EVENT_TYPE_COMMIT   => 'commit';
use constant EVENT_TYPE_IDENTITY => 'identity';
use constant EVENT_TYPE_ACCOUNT  => 'account';
use constant EVENT_TYPE_SYNC     => 'sync';

1;
