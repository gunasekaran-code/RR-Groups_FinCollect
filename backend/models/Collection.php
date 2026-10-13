<?php
class Collection extends Model
{
    protected static string $table = 'collections';

    /** The photographed proof and the customer's signature. Only the receipt
     *  being opened needs them, and this table grows by a row per payment
     *  forever — it would have been the next table to fall over. */
    protected static array $heavy = ['proof_url', 'signature_url'];
}
