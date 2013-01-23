-record(gcm_response,
        {multicast_id,
         results}).

-record(gcm_result,
        {original_id,
         canonical_id,
         error,
         message_id}).
